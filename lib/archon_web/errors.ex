# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/ApplicationExceptionMapper.java
# and ValidationExceptionMapper.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: runtime error terms instead of Java exception classes; the invalid
# value is read from the decoded struct by path instead of from a Hibernate violation.

defmodule ArchonWeb.Errors do
  @moduledoc """
  Turns runtime errors into upstream's REST error responses (ADR 0023, decision 4). This is the
  only place that picks an error status.

  | reason | upstream exception | status | `retryable` |
  |---|---|---|---|
  | `:not_found`, `{:not_found, message}` | `NotFoundException` | 404 | false |
  | `:conflict`, `{:conflict, message}` | `ConflictException` | 409 | false |
  | `{:invalid, message}` | `IllegalArgumentException` | 400 | false |
  | `{:invalid, [{path, message}]}` | `ConstraintViolationException` | 400, `validationErrors`, no `instance` | false |
  | `{:invalid_state, message}`, `{:terminate, message}` | unmapped | 500 | false |
  | `{:server_error, message}` | unmapped (a message upstream's framework writes) | 500 | false |
  | `{:payload_too_large, message}` | (a body over `ArchonWeb.Request`'s limit) | 413 | false |
  | `{:env \\| :pre_effect \\| :commit \\| :post_effect, _}`, `{:exit, _}`, a database exception | `TransientException` | 500 | true |
  | anything else | `Throwable` | 500 | false |

  A reason without a message (`:not_found`, `:conflict`) takes the upstream message from the
  `:message` option. A 500 never shows Elixir terms: its message is the given one or a fixed
  one, and the reason is logged.

  ## Validation errors

  `validate/2` errors are `{path, message}` relative to the value that was validated. Upstream
  writes each violation as `ValidationError(path, message, invalidValue)`:

    * `:path` option - the method and argument prefix upstream puts before the property path,
      such as `"registerTaskDef.arg0"`; an empty error path is the prefix alone.
    * `:value` option - the decoded value that was validated (a struct, or a list of them for a
      list argument). The invalid value is looked up there, not in the JSON text: upstream reads
      the Java field after Jackson converted it (`null` for a primitive is 0, `1.5` for an
      integer is 1). Following `ValidationExceptionMapper.getViolationInvalidValue`, strings,
      integers and booleans are written as their Java `toString`, anything else (enum, struct,
      list, map, `null`) as no `invalidValue`. No domain field holds a float (the codec has no
      floating-point type), so floats only occur inside free-form maps, which are maps.
  """

  require Logger

  alias Archon.Domain.{ErrorResponse, ValidationError}

  @transient_tags [:env, :pre_effect, :commit, :post_effect]

  @validation_message "Validation failed, check below errors for detail."
  @internal_message "Internal server error"
  @transient_message "Temporary server error, retry the request"

  @type opts :: [message: String.t(), path: String.t(), value: term()]

  @behaviour Plug

  # As a plug, the router's target for every request outside the MVP routes.
  @impl Plug
  def init(action), do: action

  @impl Plug
  def call(conn, :no_route), do: send_no_route(conn)

  @doc "Sends the error response for `reason`."
  @spec send_error(Plug.Conn.t(), term(), opts()) :: Plug.Conn.t()
  def send_error(conn, reason, opts \\ []) do
    response = error_response(reason, opts)
    ArchonWeb.Response.json(conn, response.status, ErrorResponse.to_json(response))
  end

  @doc """
  The 404 every request outside the MVP routes gets, the response upstream gives a path it has
  no handler for (`NoResourceFoundException`): `"No static resource <path>."` with the request
  path still percent-encoded and without empty segments (`/api//x/` is `api/x`).
  """
  @spec send_no_route(Plug.Conn.t()) :: Plug.Conn.t()
  def send_no_route(conn),
    do: send_error(conn, {:not_found, "No static resource #{Enum.join(conn.path_info, "/")}."})

  @doc "The error response for `reason`, see the moduledoc."
  @spec error_response(term(), opts()) :: ErrorResponse.t()
  def error_response(reason, opts \\ [])

  def error_response(:not_found, opts), do: error_response({:not_found, message!(opts)}, opts)
  def error_response(:conflict, opts), do: error_response({:conflict, message!(opts)}, opts)

  def error_response({:not_found, message}, _opts) when is_binary(message),
    do: application(404, message)

  def error_response({:conflict, message}, _opts) when is_binary(message),
    do: application(409, message)

  def error_response({:invalid, message}, _opts) when is_binary(message),
    do: application(400, message)

  def error_response({:invalid, errors}, opts) when is_list(errors) do
    %ErrorResponse{
      status: 400,
      message: @validation_message,
      retryable: false,
      validation_errors: Enum.map(errors, &validation_error(&1, opts))
    }
  end

  def error_response({:payload_too_large, message}, _opts) when is_binary(message),
    do: application(413, message)

  def error_response({tag, message}, _opts)
      when tag in [:invalid_state, :terminate, :server_error] and is_binary(message),
      do: application(500, message)

  def error_response(reason, opts) do
    transient = transient?(reason)
    Logger.error("REST request failed: #{inspect(reason)}")

    message =
      Keyword.get(opts, :message, if(transient, do: @transient_message, else: @internal_message))

    %{application(500, message) | retryable: transient}
  end

  @doc """
  The response for an exception raised while handling a request: a `Plug.Exception` status
  below 500 (a malformed query string is 400) keeps its status, anything else is a 500.
  """
  @spec exception_response(:error | :exit | :throw, term()) :: ErrorResponse.t()
  def exception_response(:error, exception) when is_exception(exception) do
    case Plug.Exception.status(exception) do
      status when status < 500 -> application(status, Exception.message(exception))
      _status -> error_response(exception)
    end
  end

  def exception_response(:exit, reason), do: error_response({:exit, reason})
  def exception_response(kind, reason), do: error_response({kind, reason})

  defp application(status, message) do
    %ErrorResponse{status: status, message: message, instance: host(), retryable: false}
  end

  defp message!(opts), do: Keyword.fetch!(opts, :message)

  # Upstream's TransientException: the step or effect failed after the workflow was read, the
  # workflow process did not answer, or the database is unreachable or failed the query.
  defp transient?({tag, _reason}) when tag in @transient_tags, do: true
  defp transient?({:exit, _reason}), do: true
  defp transient?(%DBConnection.ConnectionError{}), do: true
  defp transient?(%Postgrex.Error{}), do: true
  defp transient?(_reason), do: false

  # Utils.getServerId: the local host name.
  defp host do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  defp validation_error({path, message}, opts) do
    %ValidationError{
      path: join_path(Keyword.get(opts, :path, ""), path),
      message: message,
      invalid_value: opts |> Keyword.get(:value) |> lookup(parse_path(path)) |> java_string()
    }
  end

  # The joining rule of Archon.Domain.Validation.nest/2.
  defp join_path(prefix, ""), do: prefix
  defp join_path("", path), do: path
  defp join_path(prefix, "[" <> _rest = path), do: prefix <> path
  defp join_path(prefix, path), do: prefix <> "." <> path

  # "tasks[0].decisionCases[b][1].name" -> ["tasks", {:index, "0"}, "decisionCases", ...]
  defp parse_path(path) do
    ~r/([^.\[\]]+)|\[([^\]]*)\]/
    |> Regex.scan(path)
    |> Enum.map(fn
      [_match, name] -> {:name, name}
      [_match, "", index] -> {:index, index}
    end)
  end

  defp lookup(value, []), do: value

  defp lookup(%module{} = struct, [{:name, name} | rest]) do
    if function_exported?(module, :__fields__, 0) do
      case List.keyfind(module.__fields__(), name, 1) do
        {key, _name, _type, _opts} -> struct |> Map.fetch!(key) |> lookup(rest)
        nil -> nil
      end
    end
  end

  defp lookup(list, [{:index, index} | rest]) when is_list(list) do
    case Integer.parse(index) do
      {i, ""} -> list |> Enum.at(i) |> lookup(rest)
      _other -> nil
    end
  end

  defp lookup(map, [{_kind, key} | rest]) when is_map(map) and not is_struct(map),
    do: map |> Map.get(key) |> lookup(rest)

  defp lookup(_value, _path), do: nil

  defp java_string(value) when is_binary(value), do: value
  defp java_string(value) when is_integer(value), do: Integer.to_string(value)
  defp java_string(value) when is_boolean(value), do: Atom.to_string(value)
  defp java_string(_value), do: nil
end
