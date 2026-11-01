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

  A field with `wire: false` is internal execution state (upstream `core` `TaskModel`/`WorkflowModel`
  fields that the `common` wire classes lack). It always decodes to its default and is never
  encoded, so REST responses keep the upstream wire shape.

  The storage encoding (ADR 0021, decision 2) is the `internal: true` option of `decode/5` and
  `encode/4`, used by the `to_storage/1`/`from_storage/1` functions of the stored structs. It
  writes every field, `wire: false` and `nil` ones included, and decodes an explicit `null` as
  `nil`, so `decode(encode(struct))` gives back the same struct. Nested structs go through the
  same field-table rules (each module's `__fields__/0`) instead of their `to_json`/`from_json`,
  whose derived keys, fallbacks and truncation would change the value. A missing key still
  decodes to the field default, so rows written before a field existed keep reading.

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

  @typedoc "`internal: true` selects the storage encoding (see the moduledoc)."
  @type opts :: [internal: boolean()]

  @doc """
  Struct defaults for a field table: the value a missing JSON key decodes to.
  """
  @spec defaults([field()]) :: [{atom(), term()}]
  def defaults(fields) do
    Enum.map(fields, fn {key, _json, type, opts} -> {key, default(type, opts)} end)
  end

  @doc """
  Decodes a JSON object into `module`'s struct according to `fields`.

  `:custom` fields are passed raw to `module.decode_custom(key, value, path, codec_opts)`.
  """
  @spec decode(module(), [field()], json(), path(), opts()) :: result(struct())
  def decode(module, fields, json, path, codec_opts \\ [])

  def decode(module, fields, json, path, codec_opts) when is_map(json) do
    {attrs, errors} =
      Enum.reduce(fields, {[], []}, fn {key, _name, _type, _opts} = field, {attrs, errors} ->
        case decode_field(module, field, json, path, codec_opts) do
          {:ok, value} -> {[{key, value} | attrs], errors}
          {:error, more} -> {attrs, [more | errors]}
        end
      end)

    case errors do
      [] -> {:ok, struct!(module, attrs)}
      errors -> {:error, concat_errors(errors)}
    end
  end

  def decode(_module, _fields, _json, path, _codec_opts), do: type_error(path, "object")

  defp decode_field(module, {key, name, type, opts}, json, path, codec_opts) do
    internal? = internal?(codec_opts)
    field_path = path ++ [name]

    case field_value(json, name, opts, internal?) do
      :error ->
        {:ok, default(type, opts)}

      {:ok, nil} when internal? ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, null(type, opts)}

      {:ok, value} when type == :custom ->
        module.decode_custom(key, value, field_path, codec_opts)

      {:ok, value} ->
        cast(type, value, field_path, codec_opts)
    end
  end

  @doc """
  Encodes a struct to a JSON object according to `fields`, omitting `nil` and `wire: false`
  fields. With `internal: true` every field is written, `nil` as `null`.

  `:custom` fields are encoded with `module.encode_custom(key, value, codec_opts)`.
  """
  @spec encode(module(), [field()], struct(), opts()) :: json_object()
  def encode(module, fields, struct, codec_opts \\ []) do
    internal? = internal?(codec_opts)

    fields
    |> Enum.filter(fn {_key, _name, _type, opts} -> internal? or wire?(opts) end)
    |> Enum.reduce(%{}, fn {key, name, type, _opts}, acc ->
      case Map.fetch!(struct, key) do
        nil when internal? ->
          Map.put(acc, name, nil)

        nil ->
          acc

        value when type == :custom ->
          Map.put(acc, name, module.encode_custom(key, value, codec_opts))

        value ->
          Map.put(acc, name, encode_value(type, value, codec_opts))
      end
    end)
  end

  @doc """
  Casts one JSON value to `type`. `nil` elements of lists and maps are kept as `nil`. Nested
  structs are decoded with their module's `from_json/2`, or with `internal: true` by the storage
  encoding.
  """
  @spec cast(type(), json(), path(), opts()) :: result(term())
  def cast(type, value, path, codec_opts \\ [])
  def cast(_type, nil, _path, _codec_opts), do: {:ok, nil}

  def cast(type, value, path, codec_opts) when is_tuple(type),
    do: cast_nested(type, value, path, codec_opts)

  def cast(type, value, path, _codec_opts), do: cast_scalar(type, value, path)

  defp cast_scalar(:any, value, _path), do: {:ok, value}
  defp cast_scalar(:string, value, _path) when is_binary(value), do: {:ok, value}

  defp cast_scalar(:string, value, _path) when is_integer(value),
    do: {:ok, Integer.to_string(value)}

  defp cast_scalar(:string, value, _path) when is_float(value), do: {:ok, Float.to_string(value)}
  defp cast_scalar(:string, value, _path) when is_boolean(value), do: {:ok, Atom.to_string(value)}
  defp cast_scalar(:string, _value, path), do: type_error(path, "string")

  defp cast_scalar(type, value, path) when type in [:int, :integer], do: cast_integer(value, path)

  defp cast_scalar(type, value, path) when type in [:bool, :boolean],
    do: cast_boolean(value, path)

  defp cast_scalar(:object, value, _path) when is_map(value), do: {:ok, value}
  defp cast_scalar(:object, _value, path), do: type_error(path, "object")

  defp cast_scalar(:string_map, value, path), do: cast({:map_of, :string}, value, path)

  defp cast_nested({:enum, values}, value, path, _codec_opts) when is_binary(value) do
    case Enum.find(values, &(enum_name(&1) == value)) do
      nil -> {:error, [{format_path(path), "must be one of #{enum_names(values)}"}]}
      atom -> {:ok, atom}
    end
  end

  defp cast_nested({:enum, values}, _value, path, _codec_opts),
    do: type_error(path, "one of #{enum_names(values)}")

  defp cast_nested({:list, type}, value, path, codec_opts) when is_list(value) do
    value
    |> Enum.with_index()
    |> collect(fn {item, index} -> cast(type, item, path ++ [index], codec_opts) end)
  end

  defp cast_nested({:list, _type}, _value, path, _codec_opts), do: type_error(path, "array")

  defp cast_nested({:map_of, type}, value, path, codec_opts) when is_map(value) do
    value
    |> Enum.sort()
    |> collect(fn {key, item} ->
      with {:ok, cast} <- cast(type, item, path ++ [{:key, key}], codec_opts),
           do: {:ok, {key, cast}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp cast_nested({:map_of, _type}, _value, path, _codec_opts), do: type_error(path, "object")

  defp cast_nested({:struct, module}, value, path, codec_opts) do
    if internal?(codec_opts),
      do: decode(module, module.__fields__(), value, path, codec_opts),
      else: module.from_json(value, path)
  end

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

  @doc """
  Encodes one value of `type`. Nested structs are encoded with their module's `to_json/1`, or
  with `internal: true` by the storage encoding.
  """
  @spec encode_value(type(), term(), opts()) :: json()
  def encode_value(type, value, codec_opts \\ [])
  def encode_value(_type, nil, _codec_opts), do: nil
  def encode_value({:enum, _values}, atom, _codec_opts), do: enum_name(atom)

  def encode_value({:list, type}, list, codec_opts),
    do: Enum.map(list, &encode_value(type, &1, codec_opts))

  def encode_value({:map_of, type}, map, codec_opts),
    do: Map.new(map, fn {k, v} -> {k, encode_value(type, v, codec_opts)} end)

  def encode_value({:struct, module}, struct, codec_opts) do
    if internal?(codec_opts),
      do: encode(module, module.__fields__(), struct, codec_opts),
      else: module.to_json(struct)
  end

  def encode_value(_type, value, _codec_opts), do: value

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
          {:error, more} -> {values, [more | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(values)}
      errors -> {:error, concat_errors(errors)}
    end
  end

  # The error lists gathered newest first, in order: appending each one would copy the errors
  # so far every time, quadratic in a large body's errors.
  defp concat_errors(reversed), do: reversed |> Enum.reverse() |> Enum.concat()

  @doc "A single type error at `path`."
  @spec type_error(path(), String.t()) :: {:error, [error()]}
  def type_error(path, expected), do: {:error, [{format_path(path), "must be #{expected}"}]}

  defp field_value(json, name, opts, internal?) do
    if internal? or wire?(opts), do: Map.fetch(json, name), else: :error
  end

  defp wire?(opts), do: Keyword.get(opts, :wire, true)

  defp internal?(codec_opts), do: Keyword.get(codec_opts, :internal, false)

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
