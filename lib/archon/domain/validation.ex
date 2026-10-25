# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Domain.Validation do
  @moduledoc """
  Small helpers for the bean-validation ports in the `Archon.Domain` structs.

  Each struct's `validate/2` returns `:ok` or `{:error, [{path, message}]}`. Messages are copied
  from the upstream annotations so API error bodies can match; every check names the upstream
  annotation it comes from.

  Options shared by the validators, defaulting to upstream's shipped
  `server/src/main/resources/application.properties`:

    * `:owner_email_mandatory` - `conductor.app.ownerEmailMandatory` (default `false`)
    * `:name_validation` - `conductor.app.workflow.name-validation.enabled` (default `false`)
  """

  alias Archon.Domain.Codec

  @type opts :: [owner_email_mandatory: boolean(), name_validation: boolean()]
  @type result :: :ok | {:error, [Codec.error()]}

  @doc "Turns a list of errors into a validation result."
  @spec result([Codec.error()]) :: result()
  def result([]), do: :ok
  def result(errors), do: {:error, errors}

  @doc "Prefixes every error path with `prefix` (`\"tasks[0]\"`)."
  @spec nest([Codec.error()], String.t()) :: [Codec.error()]
  def nest(errors, prefix) do
    Enum.map(errors, fn
      {"", message} -> {prefix, message}
      {"[" <> _rest = path, message} -> {prefix <> path, message}
      {path, message} -> {prefix <> "." <> path, message}
    end)
  end

  @doc "`@NotEmpty` on a string: fails for `nil` and `\"\"`."
  @spec not_empty(String.t(), String.t() | nil, String.t()) :: [Codec.error()]
  def not_empty(path, value, message) when value in [nil, ""], do: [{path, message}]
  def not_empty(_path, _value, _message), do: []

  @doc "`@Min`: fails when `value < min`. `nil` passes, as in bean validation."
  @spec min(String.t(), integer() | nil, integer(), String.t()) :: [Codec.error()]
  def min(path, value, min, message) when is_integer(value) and value < min, do: [{path, message}]
  def min(_path, _value, _min, _message), do: []

  @doc "`@Max`: fails when `value > max`. `nil` passes, as in bean validation."
  @spec max(String.t(), integer() | nil, integer(), String.t()) :: [Codec.error()]
  def max(path, value, max, message) when is_integer(value) and value > max, do: [{path, message}]
  def max(_path, _value, _max, _message), do: []

  @doc """
  `@OwnerEmailMandatoryConstraint`
  (`common/.../constraints/OwnerEmailMandatoryConstraint.java`).
  """
  @spec owner_email(String.t() | nil, opts()) :: [Codec.error()]
  def owner_email(owner_email, opts) do
    if Keyword.get(opts, :owner_email_mandatory, false) do
      not_empty("ownerEmail", owner_email, "ownerEmail cannot be empty")
    else
      []
    end
  end

  @doc """
  `@ValidNameConstraint` (`common/.../constraints/ValidNameConstraint.java`): pattern
  `^[A-Za-z0-9_<>{}#\\s-]+$`, applied only when name validation is enabled.
  """
  @spec valid_name(String.t(), String.t() | nil, opts()) :: [Codec.error()]
  def valid_name(path, name, opts) do
    if is_binary(name) and Keyword.get(opts, :name_validation, false) and
         not Regex.match?(~r/\A[A-Za-z0-9_<>{}#\s-]+\z/, name) do
      [
        {path,
         "Invalid name '#{name}'. Allowed characters are alphanumeric, underscores, spaces, " <>
           "hyphens, and special characters like <, >, {, }, #"}
      ]
    else
      []
    end
  end
end
