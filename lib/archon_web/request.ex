# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.Request do
  @moduledoc """
  Reads request bodies and query values the way upstream's Spring handlers convert them
  (ADR 0023, decisions 1 and 4). Errors are `ArchonWeb.Errors` reasons.

  ## Body

  The body is read as text and decoded here, not by `Plug.Parsers`: the domain codecs
  (`from_json/2`) tell a missing key from `null`, and an array body arrives as the array. As
  Jackson does, the first JSON value is read and the rest ignored, and a repeated object key keeps
  its last value. Upstream answers a body that is not JSON with a 500 whose message is Jackson's
  (`"JSON parse error: ..."`); Archon keeps the status and the prefix but cannot reproduce
  Jackson's wording, except for blank text and Jackson's `StreamReadConstraints` (nesting deeper
  than 1000, a number longer than 1000 digits), whose messages are upstream's. A leading UTF-8 byte order mark is skipped, as Jackson does. The `Content-Type` is not checked (upstream answers a non-JSON one with a
  500).

  ## Query values

  `int/4`, `boolean/4` and `string/3` follow Spring's `@RequestParam` conversion
  (`CustomNumberEditor`, `CustomBooleanEditor`, checked against the upstream server):

    * A missing value, or exactly `""`, is the default.
    * A value that does not convert is a 500 with Spring's `MethodArgumentTypeMismatchException`
      message, because upstream's mapper finds no status for that exception class (ADR 0023,
      decision 4).
    * A repeated parameter converts its first value to a number or boolean, and joins all
      values with `,` for a string.
    * A pair whose `%` escapes do not decode is left out, as Tomcat does, instead of failing the
      request as `Plug.Conn.fetch_query_params/1` would.
  """

  @max_body 8_000_000
  @max_depth 1000
  @max_number 1000
  @depth_message "Document nesting depth (1001) exceeds the maximum allowed (1000, from " <>
                   "`StreamReadConstraints.getMaxNestingDepth()`)"
  # Read in chunks so that a body over the limit is refused before it is all in memory.
  @chunk 1_000_000

  @int_range -2_147_483_648..2_147_483_647

  @doc """
  Reads and decodes the JSON body. An empty or `null` body is an error, as for upstream's
  required `@RequestBody`; `:handler` completes its message with the upstream handler signature
  (`"public java.lang.String com.netflix...startWorkflow(...)"`). A body over 8 MB is a 413.
  """
  @spec read_json(Plug.Conn.t(), handler: String.t()) ::
          {:ok, Archon.Domain.Codec.json(), Plug.Conn.t()} | {:error, term(), Plug.Conn.t()}
  def read_json(conn, opts \\ []) do
    case read_all(conn, []) do
      {:ok, text, conn} -> decode(text, opts, conn)
      {:error, reason, conn} -> {:error, reason, conn}
    end
  end

  defp read_all(conn, acc) do
    case Plug.Conn.read_body(conn, length: @chunk) do
      {:ok, data, conn} -> within_limit([acc, data], conn, :ok)
      {:more, data, conn} -> within_limit([acc, data], conn, :more)
      {:error, reason} -> {:error, {:exit, {:read_body, reason}}, conn}
    end
  end

  defp within_limit(acc, conn, state) do
    cond do
      IO.iodata_length(acc) > @max_body ->
        {:error, {:payload_too_large, "Request body is larger than #{@max_body} bytes"}, conn}

      state == :ok ->
        {:ok, IO.iodata_to_binary(acc), conn}

      true ->
        read_all(conn, acc)
    end
  end

  defp decode("", opts, conn), do: {:error, missing_body(opts), conn}
  # Jackson's byte-source bootstrapper skips a UTF-8 byte order mark.
  defp decode(<<0xEF, 0xBB, 0xBF, text::binary>>, opts, conn), do: decode(text, opts, conn)

  defp decode(text, opts, conn) do
    with :ok <- not_blank(text),
         :ok <- limits(text),
         {:ok, json} when json != nil <- decode_first(text) do
      {:ok, json, conn}
    else
      {:error, detail} -> {:error, parse_error(detail), conn}
      {:ok, nil} -> {:error, missing_body(opts), conn}
      :error -> {:error, parse_error("the request body is not valid JSON"), conn}
    end
  end

  defp not_blank(text) do
    if text =~ ~r/\A[ \t\r\n]*\z/,
      do: {:error, "No content to map due to end-of-input"},
      else: :ok
  end

  defp parse_error(detail), do: {:server_error, "JSON parse error: " <> detail}

  # Jackson reads the first value and ignores what follows it, and a repeated object key keeps
  # its last value (JSON.decode/1 keeps the first). A scalar root value must be followed by
  # whitespace or the end ("123abc" and "01" fail upstream).
  defp decode_first(text) do
    decoders = %{
      null: nil,
      object_push: fn key, value, acc -> [{key, value} | acc] end,
      object_finish: fn acc, old_acc -> {acc |> Enum.reverse() |> Map.new(), old_acc} end
    }

    {value, :ok, rest} = :json.decode(text, :ok, decoders)

    if is_map(value) or is_list(value) or rest == "" or rest =~ ~r/\A[ \t\r\n]/,
      do: {:ok, value},
      else: :error
  rescue
    ErlangError -> :error
  end

  # Jackson's StreamReadConstraints, checked on the first value before :json.decode/3 builds it
  # (an 8 MB "[[[[..." takes over 1 GB, a million-digit integer seconds of CPU): nesting deeper
  # than 1000 (getMaxNestingDepth) and a number with more than 1000 digits in its integer,
  # fraction and exponent parts (getMaxNumberLength; signs, "." and "e" do not count). Text after the first value is
  # not looked at, as Jackson never reads it.
  defp limits(text), do: scan(text, 0)

  defp scan(<<>>, _level), do: :ok
  defp scan(<<?", rest::binary>>, level), do: rest |> skip_string() |> after_value(level)

  defp scan(<<char, rest::binary>>, level) when char in [?[, ?{] do
    if level + 1 > @max_depth, do: {:error, @depth_message}, else: scan(rest, level + 1)
  end

  defp scan(<<char, rest::binary>>, level) when char in [?], ?}] do
    if level <= 1, do: :ok, else: scan(rest, level - 1)
  end

  defp scan(<<char, _rest::binary>> = text, level) when char == ?- or char in ?0..?9 do
    {length, rest} = number(text, 0)

    if length > @max_number,
      do: {:error, number_message(length)},
      else: after_value(rest, level)
  end

  defp scan(<<char, rest::binary>>, level) when char in [?\s, ?\t, ?\r, ?\n, ?,, ?:],
    do: scan(rest, level)

  # A keyword (true, false, null) or anything else: a root value ends here; decoding judges it.
  defp scan(<<_char, rest::binary>>, level) when level > 0, do: scan(rest, level)
  defp scan(_text, 0), do: :ok

  defp after_value(_rest, 0), do: :ok
  defp after_value(rest, level), do: scan(rest, level)

  defp skip_string(<<?\\, _escaped, rest::binary>>), do: skip_string(rest)
  defp skip_string(<<?", rest::binary>>), do: rest
  defp skip_string(<<_char, rest::binary>>), do: skip_string(rest)
  defp skip_string(<<>>), do: <<>>

  # Digits of the integer, fraction and exponent parts.
  defp number(<<?-, rest::binary>>, 0), do: number(rest, 0)
  defp number(<<char, rest::binary>>, length) when char in ?0..?9, do: number(rest, length + 1)
  defp number(<<?., rest::binary>>, length), do: number(rest, length)

  defp number(<<char, sign, rest::binary>>, length) when char in [?e, ?E] and sign in [?+, ?-],
    do: number(rest, length)

  defp number(<<char, rest::binary>>, length) when char in [?e, ?E], do: number(rest, length)
  defp number(rest, length), do: {length, rest}

  defp number_message(length) do
    "Number value length (#{length}) exceeds the maximum allowed (1000, from " <>
      "`StreamReadConstraints.getMaxNumberLength()`)"
  end

  # HttpMessageNotReadableException: "Required request body is missing: <handler signature>".
  defp missing_body(opts) do
    message =
      case Keyword.fetch(opts, :handler) do
        {:ok, handler} -> "Required request body is missing: " <> handler
        :error -> "Required request body is missing"
      end

    {:server_error, message}
  end

  @doc """
  An integer query value. `java_type` names the handler's parameter type in the error message
  (`"int"`, or `"java.lang.Integer"` for a boxed one, which also takes blank text as `default`).
  Like `NumberUtils.parseNumber`, all whitespace is removed and `0x`/`#` hexadecimal is accepted.
  """
  @spec int(Plug.Conn.t(), String.t(), integer() | nil, String.t()) ::
          {:ok, integer() | nil} | {:error, {:server_error, String.t()}}
  def int(conn, name, default, java_type \\ "int") do
    case first_value(conn, name) do
      value when value in [nil, ""] ->
        {:ok, default}

      text ->
        case String.replace(text, ~r/\s/u, "") do
          # A boxed Integer takes blank text as null; a primitive int fails on it.
          "" when java_type == "java.lang.Integer" -> {:ok, default}
          digits -> int_result(parse_int(digits), name, java_type)
        end
    end
  end

  defp int_result({:ok, value}, _name, _java_type), do: {:ok, value}
  defp int_result({:error, detail}, name, java_type), do: mismatch(name, java_type, detail)

  defp parse_int(text) do
    {sign, rest} =
      case text do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        rest -> {1, rest}
      end

    # NumberUtils.isHexNumber takes a hexadecimal prefix only after no sign or "-".
    {digits, radix} = if sign == -1 or text == rest, do: radix(rest), else: {rest, 10}

    # Integer.valueOf and Integer.decode reject a second sign and an empty number.
    with true <- digits != "" and not String.starts_with?(digits, ["-", "+"]),
         {value, ""} <- Integer.parse(digits, radix),
         value = sign * value,
         true <- value in @int_range do
      {:ok, value}
    else
      _other -> {:error, number_format(text, digits, radix)}
    end
  end

  defp radix("0x" <> hex), do: {hex, 16}
  defp radix("0X" <> hex), do: {hex, 16}
  defp radix("#" <> hex), do: {hex, 16}
  defp radix(decimal), do: {decimal, 10}

  # NumberFormatException.forInputString: Integer.decode reports the digits after the prefix.
  defp number_format(text, _digits, 10), do: ~s(For input string: "#{text}")

  defp number_format(_text, digits, radix),
    do: ~s(For input string: "#{digits}" under radix #{radix})

  @doc """
  A boolean query value (`CustomBooleanEditor`): `true`, `on`, `yes`, `1` and `false`, `off`,
  `no`, `0`, ignoring case and surrounding whitespace. Blank text fails, as for upstream's
  primitive `boolean` parameters.
  """
  @spec boolean(Plug.Conn.t(), String.t(), boolean() | nil, String.t()) ::
          {:ok, boolean() | nil} | {:error, {:server_error, String.t()}}
  def boolean(conn, name, default, java_type \\ "boolean") do
    case first_value(conn, name) do
      value when value in [nil, ""] ->
        {:ok, default}

      text ->
        case text |> String.trim() |> String.downcase() do
          value when value in ["true", "on", "yes", "1"] -> {:ok, true}
          value when value in ["false", "off", "no", "0"] -> {:ok, false}
          _other -> mismatch(name, java_type, "Invalid boolean value [#{text}]")
        end
    end
  end

  @doc "A string query value: every value of a repeated parameter joined with `,`."
  @spec string(Plug.Conn.t(), String.t(), String.t() | nil) :: String.t() | nil
  def string(conn, name, default \\ nil) do
    case query_values(conn, name) do
      [] -> default
      [""] when default != nil -> default
      values -> Enum.join(values, ",")
    end
  end

  defp first_value(conn, name), do: conn |> query_values(name) |> List.first()

  # Tomcat's parameter parsing: `+` is a space, a pair without `=` has the value "", and a pair
  # that does not decode is dropped.
  defp query_values(conn, name) do
    conn.query_string
    |> String.split("&")
    |> Enum.flat_map(fn pair ->
      {key, value} =
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end

      case {decode(key), decode(value)} do
        {{:ok, ^name}, {:ok, value}} -> [value]
        _other -> []
      end
    end)
  end

  # URI.decode_www_form/1 keeps a malformed escape as it is; Tomcat rejects the pair.
  defp decode(text) do
    if text =~ ~r/%(?![0-9A-Fa-f]{2})/, do: :error, else: {:ok, URI.decode_www_form(text)}
  end

  defp mismatch(name, java_type, detail) do
    {:error,
     {:server_error,
      "Method parameter '#{name}': Failed to convert value of type 'java.lang.String' to " <>
        "required type '#{java_type}'; #{detail}"}}
  end
end
