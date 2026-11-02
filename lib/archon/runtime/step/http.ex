# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss http-task/src/main/java/com/netflix/conductor/tasks/http/HttpTask.java
# (start, httpCall, extractBody, Input) and
# http-task/.../providers/DefaultRestTemplateProvider.java at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff, with the messages of Spring Framework 6.2.19
# (DefaultResponseErrorHandler#getErrorMessage, RestTemplate's I/O error, HttpStatus,
# MimeTypeUtils#parseMimeType).
# Modified by sensibile: the start reads the request and posts it as an effect, and the response
# comes back as an event that this module turns into the task's result (ADR 0026, decision 7).

defmodule Archon.Runtime.Step.Http do
  @moduledoc """
  An `HTTP` task (ADR 0026, decision 7): upstream `HttpTask#start` split in two around the
  request, which `Archon.Runtime.HttpTask` sends outside the workflow process.

    * `start/2` - reads the request (`http_request`, else the whole input) and posts
      `{:http_request, task_id, poll_count, request}`. A request without `uri` or `method`, or one
      upstream refuses before it sends anything (an invalid media type, a body no converter
      writes, `headers` set to `null`, a negative timeout), fails the task as upstream's `start`
      does. An input that does not convert to upstream's `HttpTask.Input` (upstream throws out of
      `start`) leaves the task `SCHEDULED` without a request; it is `TIMED_OUT` at its response
      timeout, as upstream's executor leaves it.
    * `completed/3` - the result of the request: `COMPLETED` (or `IN_PROGRESS` with
      `asyncComplete`) with the response for a 2xx status, else `FAILED` with upstream's
      messages.

  The task's `workerId` is the node name (upstream puts its server ID there).
  """

  alias Archon.Decider.{Parameters, SystemTasks}
  alias Archon.Domain.Task
  alias Archon.Runtime.Step.State

  # TaskDef.ONE_HOUR
  @one_hour 3600

  @json "application/json"

  # HttpTask.Input defaults, and DefaultRestTemplateProvider's for a timeout set to null
  # (conductor.tasks.http.readTimeout 150ms, conductor.tasks.http.connectTimeout 100ms).
  @default_timeout 3000
  @null_read_timeout 150
  @null_connect_timeout 100

  # Spring's HttpStatus in declaration order; valueOf answers the first constant of a code.
  @reason_phrases [
    {100, "Continue"},
    {101, "Switching Protocols"},
    {102, "Processing"},
    {103, "Early Hints"},
    {200, "OK"},
    {201, "Created"},
    {202, "Accepted"},
    {203, "Non-Authoritative Information"},
    {204, "No Content"},
    {205, "Reset Content"},
    {206, "Partial Content"},
    {207, "Multi-Status"},
    {208, "Already Reported"},
    {226, "IM Used"},
    {300, "Multiple Choices"},
    {301, "Moved Permanently"},
    {302, "Found"},
    {303, "See Other"},
    {304, "Not Modified"},
    {305, "Use Proxy"},
    {307, "Temporary Redirect"},
    {308, "Permanent Redirect"},
    {400, "Bad Request"},
    {401, "Unauthorized"},
    {402, "Payment Required"},
    {403, "Forbidden"},
    {404, "Not Found"},
    {405, "Method Not Allowed"},
    {406, "Not Acceptable"},
    {407, "Proxy Authentication Required"},
    {408, "Request Timeout"},
    {409, "Conflict"},
    {410, "Gone"},
    {411, "Length Required"},
    {412, "Precondition Failed"},
    {413, "Payload Too Large"},
    {414, "URI Too Long"},
    {415, "Unsupported Media Type"},
    {416, "Requested range not satisfiable"},
    {417, "Expectation Failed"},
    {418, "I'm a teapot"},
    {419, "Insufficient Space On Resource"},
    {420, "Method Failure"},
    {421, "Destination Locked"},
    {422, "Unprocessable Entity"},
    {423, "Locked"},
    {424, "Failed Dependency"},
    {425, "Too Early"},
    {426, "Upgrade Required"},
    {428, "Precondition Required"},
    {429, "Too Many Requests"},
    {431, "Request Header Fields Too Large"},
    {451, "Unavailable For Legal Reasons"},
    {500, "Internal Server Error"},
    {501, "Not Implemented"},
    {502, "Bad Gateway"},
    {503, "Service Unavailable"},
    {504, "Gateway Timeout"},
    {505, "HTTP Version not supported"},
    {506, "Variant Also Negotiates"},
    {507, "Insufficient Storage"},
    {508, "Loop Detected"},
    {509, "Bandwidth Limit Exceeded"},
    {510, "Not Extended"},
    {511, "Network Authentication Required"}
  ]

  @reasons Map.new(@reason_phrases)

  @typedoc """
  A request for `Archon.Runtime.HttpTask`: what upstream's `RestTemplate` sends, with the
  timeouts in milliseconds (`0` waits without a limit) and `deadline`, the epoch time the task's
  response timeout ends.
  """
  @type request :: %{
          method: String.t(),
          uri: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          connect_timeout: non_neg_integer(),
          read_timeout: non_neg_integer(),
          deadline: integer()
        }

  @typedoc """
  The result of a request: the last response (redirects followed), or an I/O error with its
  cause as `RestTemplate`'s `ResourceAccessException` would end its message.
  """
  @type result ::
          {:ok, %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}}
          | {:error, {:io, String.t()}}

  @doc """
  Upstream `HttpTask#start` up to the request, for a started task (its `pollCount` counted the
  start). See the moduledoc.
  """
  @spec start(State.t(), Task.t()) :: {:started, State.t()} | {:failed, Task.t()}
  def start(%State{now: now} = state, %Task{} = task) do
    task = %{task | worker_id: worker_id()}

    case request(task.input_data) do
      {:ok, request} ->
        request = Map.put(request, :deadline, now + response_timeout(task) * 1000)
        effect = {:http_request, task.task_id, task.poll_count, request}
        {:started, state |> State.save_task(task) |> State.post(effect)}

      {:failed, reason} ->
        {:failed, failed(task, reason)}

      {:failed, reason, response} ->
        {:failed, put_output(failed(task, reason), response)}

      :invalid ->
        {:started, State.save_task(state, task)}
    end
  end

  @doc """
  When the response timeout of a started task ends (its `updateTime`, the start's save, plus the
  task's `responseTimeoutSeconds`, else an hour), as `Archon.Runtime.Step.Async` times it out.
  """
  @spec deadline(Task.t()) :: number()
  def deadline(%Task{} = task), do: task.update_time + response_timeout(task) * 1000

  defp response_timeout(%Task{response_timeout_seconds: seconds}) when seconds > 0, do: seconds
  defp response_timeout(%Task{}), do: @one_hour

  defp worker_id, do: Atom.to_string(node())

  @doc """
  The task with the result of its request: `{:done, task}`, or `:ignore` when the input no
  longer reads as a request (it cannot change while the task is `SCHEDULED`).
  """
  @spec completed(State.t(), Task.t(), result()) :: {:done, Task.t()} | :ignore
  def completed(%State{env: env}, %Task{} = task, result) do
    case request(task.input_data) do
      {:ok, request} ->
        async_complete? = SystemTasks.async_complete?(env.system_tasks, task)
        {:done, respond(task, request, result, async_complete?)}

      _other ->
        :ignore
    end
  end

  defp respond(task, request, {:ok, %{status: status} = response}, async_complete?) do
    cond do
      status in 400..599 ->
        exception(task, "java.lang.Exception: " <> error_message(request, response))

      not Map.has_key?(@reasons, status) ->
        exception(
          task,
          "java.lang.IllegalArgumentException: No matching constant for [#{status}]"
        )

      true ->
        output = %{
          "body" => if(status in 200..299, do: body(response), else: nil),
          "headers" => headers(response.headers),
          "statusCode" => status,
          "reasonPhrase" => Map.fetch!(@reasons, status)
        }

        task = put_output(task, output)

        cond do
          status not in 200..299 -> failed(task, "No response from the remote service")
          async_complete? -> %{task | status: :in_progress}
          true -> %{task | status: :completed}
        end
    end
  end

  defp respond(task, request, {:error, {:io, cause}}, _async_complete?) do
    message = ~s(I/O error on #{request.method} request for "#{request.uri}": #{cause})
    exception(task, "java.lang.Exception: " <> message)
  end

  # The catch of HttpTask#start: "Failed to invoke HTTP task due to: " + e, output e.toString().
  defp exception(task, text) do
    task |> failed("Failed to invoke HTTP task due to: " <> text) |> put_output(text)
  end

  defp failed(task, reason),
    do: %{task | status: :failed, reason_for_incompletion: reason}

  defp put_output(task, response),
    do: %{task | output_data: Map.put(task.output_data || %{}, "response", response)}

  # DefaultResponseErrorHandler#getErrorMessage: the status text, the method, the URI up to its
  # query, then the body (newlines as <EOL>, control characters as ?, quoted) or [no body].
  defp error_message(request, %{status: status} = response) do
    uri = request.uri |> String.split("?", parts: 2) |> hd()
    text = Map.get(@reasons, status, "")

    body =
      case response.body do
        "" ->
          "[no body]"

        bytes ->
          bytes
          |> decode(charset(response.headers, "UTF-8"))
          |> String.replace(~r/[\n\r]/, "<EOL>")
          |> String.replace(~r/\p{Cc}/u, "?")
          |> then(&~s("#{&1}"))
      end

    ~s(#{status} #{text} on #{request.method} request for "#{uri}": #{body})
  end

  # ResponseEntity<String>: the body read by StringHttpMessageConverter, then extractBody.
  defp body(%{body: ""}), do: nil

  defp body(%{body: bytes, headers: headers}) do
    default = if json?(content_type(headers)), do: "UTF-8", else: "ISO-8859-1"
    bytes |> decode(charset(headers, default)) |> extract_body()
  end

  # extractBody: a JSON array or object as is, a number as a Double, another JSON value as its
  # text (Jackson asText), and text that does not parse as it is.
  defp extract_body(text) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) or is_list(value) -> value
      {:ok, value} when is_number(value) -> value * 1.0
      {:ok, value} when is_binary(value) -> value
      {:ok, nil} -> "null"
      {:ok, value} when is_boolean(value) -> Atom.to_string(value)
      {:error, _reason} -> if String.trim(text) == "", do: "", else: text
    end
  end

  # HttpHeaders: each name with its values (the names as Mint gives them, lower case).
  defp headers(headers) do
    headers
    |> Enum.group_by(fn {name, _value} -> name end, fn {_name, value} -> value end)
  end

  defp content_type(headers) do
    Enum.find_value(headers, fn
      {"content-type", value} -> value
      _other -> nil
    end)
  end

  defp charset(headers, default) do
    with type when is_binary(type) <- content_type(headers),
         [_, charset] <- Regex.run(~r/;\s*charset\s*=\s*"?([^";\s]+)/i, type) do
      String.upcase(charset)
    else
      _none -> default
    end
  end

  defp decode(bytes, charset) when charset in ["ISO-8859-1", "LATIN1"],
    do: :unicode.characters_to_binary(bytes, :latin1)

  defp decode(bytes, _utf8), do: String.replace_invalid(bytes)

  ## The request

  @doc """
  The request of an `HTTP` task input (see the moduledoc): `{:ok, request}` without its
  `deadline`, `{:failed, reason}` or `{:failed, reason, response_output}` for a request upstream
  refuses, or `:invalid` for an input that is not an `HttpTask.Input`.
  """
  @spec request(map()) ::
          {:ok, map()} | {:failed, String.t()} | {:failed, String.t(), String.t()} | :invalid
  def request(input) do
    request =
      case Map.get(input, "http_request") do
        nil -> input
        request -> request
      end

    with {:ok, input} <- input(request), do: checked(input)
  end

  defp checked(%{uri: nil}),
    do:
      {:failed, "Missing HTTP URI.  See documentation for HttpTask for required input parameters"}

  defp checked(%{method: nil}), do: {:failed, "No HTTP method specified"}

  defp checked(input) do
    case build(input) do
      {:ok, request} -> {:ok, request}
      {:error, text} -> {:failed, "Failed to invoke HTTP task due to: " <> text, text}
    end
  end

  # objectMapper.convertValue(request, HttpTask.Input.class), unknown keys ignored.
  defp input(json) when is_map(json) do
    with {:ok, method} <- string(json, "method"),
         {:ok, uri} <- string(json, "uri"),
         {:ok, content_type} <- string(json, "contentType", @json),
         {:ok, headers} <- headers_input(json),
         {:ok, connect} <- integer(json, "connectionTimeOut"),
         {:ok, read} <- integer(json, "readTimeOut"),
         {:ok, _vip} <- string(json, "vipAddress"),
         {:ok, _app} <- string(json, "appName") do
      {:ok,
       %{
         method: method,
         uri: uri,
         content_type: content_type,
         headers: headers,
         accept: accept(Map.get(json, "accept")),
         body: Map.get(json, "body"),
         connect_timeout: connect,
         read_timeout: read
       }}
    else
      :error -> :invalid
    end
  end

  defp input(_not_object), do: :invalid

  # A String property takes any JSON scalar as its text.
  defp string(json, key, default \\ nil) do
    case Map.fetch(json, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, value} when is_number(value) or is_boolean(value) ->
        {:ok, Parameters.java_string(value)}

      {:ok, _container} ->
        :error
    end
  end

  defp headers_input(json) do
    case Map.fetch(json, "headers") do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, nil}
      {:ok, headers} when is_map(headers) -> {:ok, headers}
      {:ok, _other} -> :error
    end
  end

  # An Integer property: a whole number in range, a fraction cut to it, or a decimal string.
  defp integer(json, key) do
    case Map.fetch(json, key) do
      :error -> {:ok, @default_timeout}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) -> int_range(value)
      {:ok, value} when is_float(value) -> int_range(trunc(value))
      {:ok, value} when is_binary(value) -> parse_integer(String.trim(value))
      {:ok, _other} -> :error
    end
  end

  defp parse_integer(""), do: {:ok, nil}

  defp parse_integer(text) do
    case Integer.parse(text) do
      {value, ""} -> int_range(value)
      _other -> :error
    end
  end

  defp int_range(value) when value in -2_147_483_648..2_147_483_647, do: {:ok, value}
  defp int_range(_value), do: :error

  # setAccept: a string, or each element of a list as its text; anything else is ignored.
  defp accept(value) when is_binary(value), do: [value]
  defp accept(values) when is_list(values), do: Enum.map(values, &Parameters.java_string/1)
  defp accept(_other), do: [@json]

  # httpCall up to restTemplate.exchange, with what it throws on the way.
  defp build(input) do
    with {:ok, read} <- timeout(input.read_timeout, @null_read_timeout),
         {:ok, connect} <- timeout(input.connect_timeout, @null_connect_timeout),
         :ok <- media_type(input.content_type),
         :ok <- Enum.reduce_while(input.accept, :ok, &media_type_step/2),
         {:ok, headers} <- request_headers(input),
         {:ok, body} <- request_body(input) do
      {:ok,
       %{
         method: input.method,
         uri: input.uri,
         headers: headers,
         body: body,
         connect_timeout: connect,
         read_timeout: read
       }}
    end
  end

  defp timeout(nil, default), do: {:ok, default}
  defp timeout(ms, _default) when ms >= 0, do: {:ok, ms}

  defp timeout(_negative, _default),
    do: {:error, "java.lang.IllegalArgumentException: Timeout must be a non-negative value"}

  defp media_type_step(type, :ok) do
    case media_type(type) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  # MediaType.valueOf, as far as MimeTypeUtils#parseMimeType refuses a type.
  defp media_type(type) do
    full = if type == nil, do: "null", else: type
    reason = if type in [nil, ""], do: "'mimeType' must not be empty", else: mime_error(type)

    if reason == nil,
      do: :ok,
      else:
        {:error,
         ~s(org.springframework.http.InvalidMediaTypeException: Invalid mime type "#{full}": #{reason})}
  end

  defp mime_error(type) do
    main = type |> String.split(";", parts: 2) |> hd() |> String.trim()

    cond do
      not String.contains?(main, "/") ->
        "does not contain '/'"

      String.ends_with?(main, "/") ->
        "does not contain subtype after '/'"

      String.starts_with?(main, "*/") and main != "*/*" ->
        "wildcard type is legal only in '*/*' (all mime types)"

      true ->
        nil
    end
  end

  # Content-Type, Accept, then each header with a value (as its text).
  defp request_headers(%{headers: nil}) do
    {:error,
     ~S|java.lang.NullPointerException: Cannot invoke "java.util.Map.forEach(java.util.function.BiConsumer)" because "input.headers" is null|}
  end

  defp request_headers(input) do
    own =
      for {name, value} <- input.headers, value != nil, do: {name, Parameters.java_string(value)}

    {:ok, [{"Content-Type", input.content_type}, {"Accept", Enum.join(input.accept, ", ")} | own]}
  end

  # RestTemplate's converters: a string as it is, anything else as JSON, which only a JSON
  # media type takes.
  defp request_body(%{body: nil}), do: {:ok, nil}
  defp request_body(%{body: body}) when is_binary(body), do: {:ok, body}

  defp request_body(%{body: body, content_type: type}) do
    if json?(type) do
      {:ok, Jason.encode!(body)}
    else
      {:error,
       ~s(java.lang.Exception: No HttpMessageConverter for #{java_class(body)} and content type "#{type}")}
    end
  end

  defp json?(nil), do: false

  defp json?(type) do
    main = type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    main == @json or
      (String.starts_with?(main, "application/") and String.ends_with?(main, "+json"))
  end

  defp java_class(value) when is_map(value), do: "java.util.LinkedHashMap"
  defp java_class(value) when is_list(value), do: "java.util.ArrayList"
  defp java_class(value) when is_boolean(value), do: "java.lang.Boolean"
  defp java_class(value) when is_float(value), do: "java.lang.Double"
  defp java_class(value) when value in -2_147_483_648..2_147_483_647, do: "java.lang.Integer"

  defp java_class(value) when value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
    do: "java.lang.Long"

  defp java_class(_value), do: "java.math.BigInteger"
end
