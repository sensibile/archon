# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Reproduces the JSON behaviour of upstream's Jackson ObjectMapper
# (conductor-oss common/src/main/java/com/netflix/conductor/common/config/ObjectMapperProvider.java,
# commit 1488804170d159021c7e62dce61514b8f31ef9ff). No upstream code is translated here.

defmodule Archon.Domain.Codec do
  @moduledoc """
  Field-table driven JSON codec shared by the `Archon.Domain` structs.

  Each struct module declares its fields as `{key, json_name, type, opts}` and delegates decoding
  and encoding here. The rules mirror the upstream Jackson configuration
  (`ObjectMapperProvider`), which is what Conductor clients actually see on the wire:

    * Unknown JSON keys are ignored (`FAIL_ON_UNKNOWN_PROPERTIES = false`).
    * A missing key leaves the field at its default, i.e. the Java field initializer
      (`:default` option).
    * An explicit `null` is stored as the `:null` option. For boxed Java types and collections
      that is `nil`; for Java primitives (`:int`, `:bool`) it is the zero value
      (`FAIL_ON_NULL_FOR_PRIMITIVES = false`); setters and getters that replace `null` with a
      fallback set `:null` to that fallback.
    * Encoding omits `nil` fields (`Include.NON_NULL`) and keeps `null` values inside free-form
      maps (content inclusion `ALWAYS`).
    * Scalars are coerced the way Jackson does by default: integral strings and floats to
      integers, `"true"`/`"false"` to booleans and numbers or booleans to strings.

  Enums are atoms on the Elixir side and upstream's constant names on the wire
  (`:time_out_wf` <-> `"TIME_OUT_WF"`).

  Decoding returns every type error at once as `{path, message}` with a bean-style path such as
  `"tasks[0].decisionCases[b][1].startDelay"`.
  """

  @typedoc "Decoded JSON as produced by `JSON.decode/1`."
  @type json ::
          nil | boolean() | number() | String.t() | [json()] | %{optional(String.t()) => json()}

  @type json_object :: %{optional(String.t()) => json()}

  @typedoc "A decode or validation failure: bean-style property path and message."
  @type error :: {String.t(), String.t()}

  @type path :: [String.t() | non_neg_integer() | {:key, String.t()}]

  @type type ::
          :string
          | :int
          | :integer
          | :bool
          | :boolean
          | :object
          | :string_map
          | :any
          | {:enum, [atom()]}
          | {:list, type()}
          | {:map_of, type()}
          | {:struct, module()}
          | :custom

  @type field :: {atom(), String.t(), type(), keyword()}

  @typedoc "Result of decoding one value."
  @type result(value) :: {:ok, value} | {:error, [error()]}

  @doc """
  Struct defaults for a field table: the value a missing JSON key decodes to.
  """
  @spec defaults([field()]) :: [{atom(), term()}]
  def defaults(fields) do
    Enum.map(fields, fn {key, _json, type, opts} -> {key, default(type, opts)} end)
  end

  @doc """
  Decodes a JSON object into `module`'s struct according to `fields`.

  `:custom` fields are passed raw to `module.decode_custom(key, value, path)`.
  """
  @spec decode(module(), [field()], json(), path()) :: result(struct())
  def decode(module, fields, json, path) when is_map(json) do
    {attrs, errors} =
      Enum.reduce(fields, {[], []}, fn {key, name, type, opts}, {attrs, errors} ->
        field_path = path ++ [name]

        result =
          case Map.fetch(json, name) do
            :error -> {:ok, default(type, opts)}
            {:ok, nil} -> {:ok, null(type, opts)}
            {:ok, value} when type == :custom -> module.decode_custom(key, value, field_path)
            {:ok, value} -> cast(type, value, field_path)
          end

        case result do
          {:ok, value} -> {[{key, value} | attrs], errors}
          {:error, more} -> {attrs, errors ++ more}
        end
      end)

    case errors do
      [] -> {:ok, struct!(module, attrs)}
      errors -> {:error, errors}
    end
  end

  def decode(_module, _fields, _json, path), do: type_error(path, "object")

  @doc """
  Encodes a struct to a JSON object according to `fields`, omitting `nil` fields.

  `:custom` fields are encoded with `module.encode_custom(key, value)`.
  """
  @spec encode(module(), [field()], struct()) :: json_object()
  def encode(module, fields, struct) do
    Enum.reduce(fields, %{}, fn {key, name, type, _opts}, acc ->
      case Map.fetch!(struct, key) do
        nil -> acc
        value when type == :custom -> Map.put(acc, name, module.encode_custom(key, value))
        value -> Map.put(acc, name, encode_value(type, value))
      end
    end)
  end

  @doc "Casts one JSON value to `type`. `nil` elements of lists and maps are kept as `nil`."
  @spec cast(type(), json(), path()) :: result(term())
  def cast(_type, nil, _path), do: {:ok, nil}
  def cast(:any, value, _path), do: {:ok, value}

  def cast(:string, value, _path) when is_binary(value), do: {:ok, value}
  def cast(:string, value, _path) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def cast(:string, value, _path) when is_float(value), do: {:ok, Float.to_string(value)}
  def cast(:string, value, _path) when is_boolean(value), do: {:ok, Atom.to_string(value)}
  def cast(:string, _value, path), do: type_error(path, "string")

  def cast(type, value, path) when type in [:int, :integer], do: cast_integer(value, path)
  def cast(type, value, path) when type in [:bool, :boolean], do: cast_boolean(value, path)

  def cast(:object, value, _path) when is_map(value), do: {:ok, value}
  def cast(:object, _value, path), do: type_error(path, "object")

  def cast(:string_map, value, path), do: cast({:map_of, :string}, value, path)

  def cast({:enum, values}, value, path) when is_binary(value) do
    case Enum.find(values, &(enum_name(&1) == value)) do
      nil -> {:error, [{format_path(path), "must be one of #{enum_names(values)}"}]}
      atom -> {:ok, atom}
    end
  end

  def cast({:enum, values}, _value, path), do: type_error(path, "one of #{enum_names(values)}")

  def cast({:list, type}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> collect(fn {item, index} -> cast(type, item, path ++ [index]) end)
  end

  def cast({:list, _type}, _value, path), do: type_error(path, "array")

  def cast({:map_of, type}, value, path) when is_map(value) do
    value
    |> Enum.sort()
    |> collect(fn {key, item} ->
      with {:ok, cast} <- cast(type, item, path ++ [{:key, key}]), do: {:ok, {key, cast}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  def cast({:map_of, _type}, _value, path), do: type_error(path, "object")

  def cast({:struct, module}, value, path), do: module.from_json(value, path)

  defp cast_integer(value, _path) when is_integer(value), do: {:ok, value}
  # DeserializationFeature.ACCEPT_FLOAT_AS_INT is enabled by default: the fraction is dropped.
  defp cast_integer(value, _path) when is_float(value), do: {:ok, trunc(value)}

  defp cast_integer(value, path) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _other -> type_error(path, "integer")
    end
  end

  defp cast_integer(_value, path), do: type_error(path, "integer")

  defp cast_boolean(value, _path) when is_boolean(value), do: {:ok, value}
  defp cast_boolean("true", _path), do: {:ok, true}
  defp cast_boolean("false", _path), do: {:ok, false}
  defp cast_boolean(_value, path), do: type_error(path, "boolean")

  @doc "Encodes one value of `type`."
  @spec encode_value(type(), term()) :: json()
  def encode_value(_type, nil), do: nil
  def encode_value({:enum, _values}, atom), do: enum_name(atom)
  def encode_value({:list, type}, list), do: Enum.map(list, &encode_value(type, &1))

  def encode_value({:map_of, type}, map),
    do: Map.new(map, fn {k, v} -> {k, encode_value(type, v)} end)

  def encode_value({:struct, module}, struct), do: module.to_json(struct)
  def encode_value(_type, value), do: value

  @doc "Upstream constant name of an enum atom: `:time_out_wf` -> `\"TIME_OUT_WF\"`."
  @spec enum_name(atom()) :: String.t()
  def enum_name(atom), do: atom |> Atom.to_string() |> String.upcase()

  @doc "Renders a path as `tasks[0].decisionCases[b][1].name`."
  @spec format_path(path()) :: String.t()
  def format_path(path) do
    Enum.reduce(path, "", fn
      index, acc when is_integer(index) -> acc <> "[#{index}]"
      {:key, key}, acc -> acc <> "[#{key}]"
      name, "" -> name
      name, acc -> acc <> "." <> name
    end)
  end

  @doc "Runs `fun` over `items`, returning all values or every error."
  @spec collect(Enumerable.t(), (term() -> result(term()))) :: result([term()])
  def collect(items, fun) do
    {values, errors} =
      Enum.reduce(items, {[], []}, fn item, {values, errors} ->
        case fun.(item) do
          {:ok, value} -> {[value | values], errors}
          {:error, more} -> {values, errors ++ more}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(values)}
      errors -> {:error, errors}
    end
  end

  @doc "A single type error at `path`."
  @spec type_error(path(), String.t()) :: {:error, [error()]}
  def type_error(path, expected), do: {:error, [{format_path(path), "must be #{expected}"}]}

  defp default(type, opts), do: Keyword.get(opts, :default, zero(type))

  defp null(type, opts) do
    case Keyword.get(opts, :null, zero(type)) do
      :default -> default(type, opts)
      value -> value
    end
  end

  defp zero(:int), do: 0
  defp zero(:bool), do: false
  defp zero(_type), do: nil

  defp enum_names(values), do: Enum.map_join(values, ", ", &enum_name/1)
end
