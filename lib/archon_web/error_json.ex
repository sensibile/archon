# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.ErrorJSON do
  @moduledoc """
  The endpoint's `render_errors` view, for an exception the router's error handler did not
  answer (one raised before routing). It writes the same `ErrorResponse` body as
  `ArchonWeb.Errors`.
  """

  alias Archon.Domain.ErrorResponse

  @doc false
  @spec render(String.t(), map()) :: Archon.Domain.Codec.json_object()
  def render(_template, %{kind: kind, reason: reason}),
    do: kind |> ArchonWeb.Errors.exception_response(reason) |> ErrorResponse.to_json()
end
