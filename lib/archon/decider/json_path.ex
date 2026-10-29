# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Reproduces the subset of Jayway JsonPath 2.4.0 that upstream's ParametersUtils relies on
# (conductor-oss core/src/main/java/com/netflix/conductor/core/utils/ParametersUtils.java,
# commit 1488804170d159021c7e62dce61514b8f31ef9ff). No JsonPath code is translated here.

defmodule Archon.Decider.JsonPath do
  @moduledoc """
  The definite-path subset of Jayway JsonPath used by `${...}` input references (ADR 0014).

  Upstream reads paths with `Option.SUPPRESS_EXCEPTIONS`, so a path that does not resolve, or
  that does not compile, reads as `null`. `read/2` returns `nil` in the same cases.

  Supported syntax, after trimming and an optional `$` root (a path without it gets `$.`
  prepended, as Jayway does):

    * dot notation: `a.b.c` (a property name ends at `.`, `[`, `(` or whitespace)
    * quoted brackets: `['a b']`, `["a.b"]`, also right after the root (`['a']`, `$.['a']`);
      a backslash escapes the next character, with `\\uXXXX`, `\\n`, `\\t`, `\\r`, `\\b` and `\\f`
      decoded
    * array indexes: `[0]`, `[-1]` (from the end)
    * wildcards: `[*]` and `.*`, over list elements or map values

  A path with a wildcard is indefinite: it reads as the list of everything it reaches, skipping
  branches that do not resolve, as Jayway does. Map values come in key order, since Elixir maps
  do not keep JSON key order (ADR 0002).

  Everything else Jayway accepts (deep scan `..`, filters, slices, unions, functions, the `@`
  root) is not supported and reads as `nil`.
  """

  @typedoc "Decoded JSON."
  @type json :: Archon.Domain.Codec.json()

  @type token :: {:property, String.t()} | {:index, integer()} | :wildcard

  @doc """
  Reads `path` from `document`, or `nil` when it does not resolve or is not supported.
  """
  @spec read(json(), String.t()) :: json()
  def read(document, path) do
    case compile(path) do
      {:ok, tokens} -> document |> collect(tokens) |> result(:wildcard in tokens)
      :error -> nil
    end
  end

  defp result(values, true = _indefinite), do: values
  defp result([], false), do: nil
  defp result([value | _rest], false), do: value

  @doc "Compiles `path` into tokens, or `:error` for unsupported or invalid syntax."
  @spec compile(String.t()) :: {:ok, [token()]} | :error
  def compile(path) do
    case String.trim(path) do
      "$" <> rest -> tokens(rest, [])
      "@" <> _rest -> :error
      relative -> tokens("." <> relative, [])
    end
  end

  defp tokens("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokens(".*" <> rest, acc), do: tokens(rest, [:wildcard | acc])
  defp tokens(".[" <> rest, acc), do: tokens("[" <> rest, acc)

  defp tokens("." <> rest, acc) do
    case Regex.run(~r/\A[^.\[\(\s]+/, rest) do
      [name] ->
        case binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name)) do
          "(" <> _function -> :error
          more -> tokens(more, [{:property, name} | acc])
        end

      nil ->
        :error
    end
  end

  defp tokens("[" <> rest, acc) do
    case Regex.run(~r/\A\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"|(-?\d+)|(\*))\s*\]/s, rest) do
      [match | groups] ->
        token =
          case groups do
            [single] -> {:property, unescape(single)}
            ["", double] -> {:property, unescape(double)}
            ["", "", index] -> {:index, String.to_integer(index)}
            ["", "", "", "*"] -> :wildcard
          end

        tokens(binary_part(rest, byte_size(match), byte_size(rest) - byte_size(match)), [
          token | acc
        ])

      nil ->
        :error
    end
  end

  defp tokens(_rest, _acc), do: :error

  defp unescape(name) do
    Regex.replace(~r/\\(u[0-9a-fA-F]{4}|.)/s, name, fn _match, escaped ->
      case escaped do
        "u" <> hex -> code_point(String.to_integer(hex, 16))
        "n" -> "\n"
        "t" -> "\t"
        "r" -> "\r"
        "b" -> "\b"
        "f" -> "\f"
        other -> other
      end
    end)
  end

  # A lone UTF-16 surrogate cannot be a key of decoded JSON; keep it from raising.
  defp code_point(code) when code in 0xD800..0xDFFF, do: "\\u" <> Integer.to_string(code, 16)
  defp code_point(code), do: <<code::utf8>>

  # Every value `tokens` reaches from `value`; branches that do not resolve add nothing.
  defp collect(value, []), do: [value]

  defp collect(map, [{:property, name} | rest]) when is_map(map) do
    case Map.fetch(map, name) do
      {:ok, value} -> collect(value, rest)
      :error -> []
    end
  end

  defp collect(list, [{:index, index} | rest]) when is_list(list) do
    position = if index < 0, do: length(list) + index, else: index

    if position >= 0 and position < length(list),
      do: list |> Enum.at(position) |> collect(rest),
      else: []
  end

  defp collect(list, [:wildcard | rest]) when is_list(list),
    do: Enum.flat_map(list, &collect(&1, rest))

  defp collect(map, [:wildcard | rest]) when is_map(map) do
    map |> Enum.sort() |> Enum.flat_map(fn {_key, value} -> collect(value, rest) end)
  end

  defp collect(_value, _tokens), do: []
end
