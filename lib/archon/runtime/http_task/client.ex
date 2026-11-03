# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from the behaviour of conductor-oss http-task's DefaultRestTemplateProvider
# (a new Apache HttpClient 5 client per request: its connect and socket timeouts, redirects and
# content decompression) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: one Mint connection per request, with a total time limit and a
# response body limit (ADR 0026, decision 7).

defmodule Archon.Runtime.HttpTask.Client do
  @moduledoc """
  Sends one `HTTP` task request (`t:Archon.Runtime.Step.Http.request/0`) with Mint, as
  upstream's client per request does (ADR 0026, decision 7):

    * a new connection, `connect_timeout` to open it and `read_timeout` for each read (`0` is no
      limit, as Apache HttpClient's);
    * `Accept-Encoding: gzip, x-gzip, deflate`, and a body in one of those decompressed, without
      its `content-length`, `content-encoding` and `content-md5` headers (HttpClient's
      `ContentCompressionExec`);
    * redirects followed as HttpClient's `RedirectExec`: `301`, `302`, `303`, `307` and `308` with
      a `location`, a `303` (and a `301` or `302` of a `POST`) as a `GET` without the body, at most
      50, none to a location already visited.

  Two limits upstream does not have bound what a request holds: the whole request, redirects
  included, ends at `total_ms`, and a body (read or decompressed) larger than `max_body` bytes
  ends it. Both are I/O errors, as a timeout is.

  Returns `t:Archon.Runtime.Step.Http.result/0`. The connection belongs to the calling process,
  so ending that process closes it.
  """

  alias Archon.Runtime.Step.Http

  @accept_encoding "gzip, x-gzip, deflate"
  @redirects [301, 302, 303, 307, 308]
  @max_redirects 50
  @decoded_drops ["content-length", "content-encoding", "content-md5"]

  @type limits :: %{total_ms: pos_integer(), max_body: pos_integer()}

  @doc "Sends `request` within `limits` (see the moduledoc)."
  @spec run(Http.request(), limits()) :: Http.result()
  def run(request, %{total_ms: total_ms} = limits) do
    ends = now() + total_ms
    follow(request, limits, ends, [], 0)
  end

  defp follow(request, limits, ends, visited, hops) do
    with {:ok, response} <- exchange(request, limits, ends) do
      case redirect(request, response) do
        nil ->
          decoded(response, limits)

        # The bodies of the responses redirected from count toward the body limit too.
        {location, next} ->
          limits =
            Map.update(limits, :read, byte_size(response.body), &(&1 + byte_size(response.body)))

          follow_to(next, location, limits, ends, visited, hops)
      end
    end
  end

  defp follow_to(_next, _location, _limits, _ends, _visited, hops) when hops >= @max_redirects,
    do: {:error, {:io, "Maximum redirects (#{@max_redirects}) exceeded"}}

  defp follow_to(next, location, limits, ends, visited, hops) do
    if location in visited,
      do: {:error, {:io, "Circular redirect to '#{location}'"}},
      else: follow(next, limits, ends, [location | visited], hops + 1)
  end

  defp redirect(request, %{status: status, headers: headers}) when status in @redirects do
    case List.keyfind(headers, "location", 0) do
      {"location", location} ->
        location = request.uri |> URI.merge(location) |> URI.to_string()

        next = redirected(request, status, location)
        if redirect_allowed?(request, next), do: {location, next}, else: nil

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp redirect(_request, _response), do: nil

  # DefaultRedirectStrategy#isRedirectAllowed, asked about the redirect request: one with an
  # Authorization or Cookie header does not go to another host or port; the redirect is then the
  # response.
  defp redirect_allowed?(request, next) do
    same_authority?(URI.parse(request.uri), URI.parse(next.uri)) or
      not Enum.any?(next.headers, fn {name, _value} ->
        String.downcase(name) in ["authorization", "cookie"]
      end)
  end

  defp same_authority?(%URI{host: host, port: port}, %URI{host: other, port: port})
       when is_binary(host) and is_binary(other),
       do: String.downcase(host) == String.downcase(other)

  defp same_authority?(_uri, _other), do: false

  defp redirected(request, status, location) do
    get? =
      (status == 303 and request.method not in ["GET", "HEAD"]) or
        (status in [301, 302] and request.method == "POST")

    # ClassicRequestBuilder.get(): a new GET without the original headers or body.
    if get?,
      do: %{request | uri: location, method: "GET", headers: [], body: nil},
      else: %{request | uri: location}
  end

  defp exchange(request, limits, ends) do
    with {:ok, target} <- target(request.uri),
         {:ok, conn} <- connect(target, request, ends) do
      result = send_request(conn, target, request, limits, ends)
      close(conn, result)
      result
    end
  end

  # A request ended early drops what the target did not take (no linger: a close would otherwise
  # wait for the send queue); one that is done closes as usual.
  defp close(conn, {:error, _reason}) do
    socket = Mint.HTTP.get_socket(conn)
    opts = [linger: {true, 0}]
    _ = if is_port(socket), do: :inet.setopts(socket, opts), else: :ssl.setopts(socket, opts)
    Mint.HTTP.close(conn)
  end

  defp close(conn, _done), do: Mint.HTTP.close(conn)

  defp target(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme, host: host} = parsed}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path = if parsed.path in [nil, ""], do: "/", else: parsed.path
        path = if parsed.query, do: path <> "?" <> parsed.query, else: path

        {:ok,
         %{scheme: String.to_existing_atom(scheme), host: host, port: parsed.port, path: path}}

      {:ok, %URI{scheme: scheme}} when scheme not in [nil, "http", "https"] ->
        {:error, {:io, "#{scheme} protocol is not supported"}}

      {:ok, _relative} ->
        {:error, {:io, "Target host is not specified"}}

      {:error, part} ->
        {:error, {:io, "Illegal character in URI at: #{part}"}}
    end
  end

  defp connect(target, request, ends) do
    opts = [
      mode: :passive,
      protocols: [:http1],
      # A send to a target that does not read ends at the total limit too.
      transport_opts: [
        timeout: wait(request.connect_timeout, ends),
        send_timeout: max(wait(0, ends), 1),
        send_timeout_close: true
      ]
    ]

    case Mint.HTTP.connect(target.scheme, target.host, target.port, opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, error} -> {:error, {:io, connect_error(target, error, ends)}}
    end
  end

  # HttpHostConnectException and its JDK causes.
  defp connect_error(target, %Mint.TransportError{reason: reason}, ends) do
    origin = "#{target.scheme}://#{target.host}:#{target.port}"

    case reason do
      :econnrefused ->
        "Connect to #{origin} failed: Connection refused (connect failed)"

      :timeout ->
        if over?(ends), do: total_error(), else: "Connect to #{origin} failed: Connect timed out"

      :nxdomain ->
        "#{target.host}: Name or service not known"

      other ->
        "Connect to #{origin} failed: #{Mint.TransportError.message(%Mint.TransportError{reason: other})}"
    end
  end

  defp connect_error(target, error, _ends),
    do:
      "Connect to #{target.scheme}://#{target.host}:#{target.port} failed: #{Exception.message(error)}"

  defp send_request(conn, target, request, limits, ends) do
    # ContentCompressionExec adds the header unless the request has one.
    headers =
      if Enum.any?(request.headers, &accept_encoding?/1),
        do: request.headers,
        else: request.headers ++ [{"Accept-Encoding", @accept_encoding}]

    case Mint.HTTP.request(conn, request.method, target.path, headers, request.body) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, request, limits, ends, %{
          status: nil,
          headers: [],
          body: "",
          size: 0
        })

      {:error, _conn, error} ->
        {:error, {:io, if(over?(ends), do: total_error(), else: Exception.message(error))}}
    end
  end

  defp accept_encoding?({name, _value}), do: String.downcase(name) == "accept-encoding"

  defp receive_response(conn, ref, request, limits, ends, acc) do
    if over?(ends),
      do: {:error, {:io, total_error()}},
      else: receive_more(conn, ref, request, limits, ends, acc)
  end

  defp receive_more(conn, ref, request, limits, ends, acc) do
    case Mint.HTTP.recv(conn, 0, wait(request.read_timeout, ends)) do
      {:ok, conn, responses} ->
        case collect(responses, ref, limits, acc) do
          {:done, acc} ->
            {:ok,
             %{
               status: acc.status,
               headers: acc.headers,
               body: acc.body
             }}

          {:more, acc} ->
            receive_response(conn, ref, request, limits, ends, acc)

          {:error, _reason} = error ->
            error
        end

      {:error, _conn, %Mint.TransportError{reason: :timeout}, _responses} ->
        {:error, {:io, if(over?(ends), do: total_error(), else: "Read timed out")}}

      {:error, _conn, error, _responses} ->
        {:error, {:io, Exception.message(error)}}
    end
  end

  defp collect([], _ref, _limits, acc), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, limits, acc),
    do: collect(rest, ref, limits, %{acc | status: status})

  # Informational answers (100 Continue) are not the response.
  defp collect([{:headers, ref, _headers} | rest], ref, limits, %{status: status} = acc)
       when status in 100..199,
       do: collect(rest, ref, limits, %{acc | status: nil})

  defp collect([{:headers, ref, headers} | rest], ref, limits, %{headers: []} = acc),
    do: collect(rest, ref, limits, %{acc | headers: headers})

  # Trailers.
  defp collect([{:headers, ref, _trailers} | rest], ref, limits, acc),
    do: collect(rest, ref, limits, acc)

  defp collect([{:data, ref, data} | rest], ref, limits, acc) do
    size = acc.size + byte_size(data)

    if size + Map.get(limits, :read, 0) > limits.max_body,
      do: body_error(limits),
      # Appended to one binary (the runtime grows it in place), so many small chunks do not cost
      # a list cell and a sub-binary each.
      else: collect(rest, ref, limits, %{acc | body: acc.body <> data, size: size})
  end

  defp collect([{:done, ref} | _rest], ref, _limits, acc), do: {:done, acc}

  defp collect([{:error, ref, error} | _rest], ref, _limits, _acc),
    do: {:error, {:io, Exception.message(error)}}

  defp collect([_other | rest], ref, limits, acc), do: collect(rest, ref, limits, acc)

  # ContentCompressionExec: a body in a known coding is decompressed; another is left as it is.
  defp decoded(%{headers: headers, body: body} = response, limits) do
    coding =
      Enum.find_value(headers, fn
        {"content-encoding", value} -> value |> String.trim() |> String.downcase()
        _other -> nil
      end)

    window =
      case coding do
        coding when coding in ["gzip", "x-gzip"] -> [31]
        "deflate" -> [15, -15]
        _other -> nil
      end

    if window == nil or body == "",
      do: {:ok, response},
      else: inflated(response, window, limits)
  end

  defp inflated(%{headers: headers, body: body} = response, window, limits) do
    with {:ok, body} <- inflate(body, window, limits.max_body) do
      headers = Enum.reject(headers, fn {name, _value} -> name in @decoded_drops end)
      {:ok, %{response | headers: headers, body: body}}
    end
  end

  # A deflate body with a zlib header, else raw (DeflateInputStream).
  defp inflate(body, [window | others], max_body) do
    case inflate_with(body, window, max_body) do
      {:error, {:io, "corrupt"}} when others != [] -> inflate(body, others, max_body)
      {:error, {:io, "corrupt"}} -> {:error, {:io, "Corrupt input data in the response body"}}
      result -> result
    end
  end

  defp inflate_with(body, window, max_body) do
    z = :zlib.open()

    try do
      # GZIPInputStream reads every member of a gzip body one after the other.
      :ok = :zlib.inflateInit(z, window, if(window == 31, do: :reset, else: :cut))
      # An empty member gives no output; a step without output is allowed once per member the
      # input can hold (a gzip member is at least 18 bytes), so the loop ends whatever the input.
      inflate_loop(z, :zlib.safeInflate(z, body), [], 0, {max_body, div(byte_size(body), 18) + 2})
    catch
      :error, _reason -> {:error, {:io, "corrupt"}}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {status, out}, acc, size, {max_body, idle}) do
    length = IO.iodata_length(out)
    size = size + length
    idle = if length == 0, do: idle - 1, else: idle

    cond do
      size > max_body -> body_error(%{max_body: max_body})
      # inflateEnd raises on a stream cut before its end (GZIPInputStream's EOFException).
      status == :finished -> finish_inflate(z, [out | acc])
      idle < 0 -> {:error, {:io, "corrupt"}}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), [out | acc], size, {max_body, idle})
    end
  end

  defp finish_inflate(z, acc) do
    :ok = :zlib.inflateEnd(z)
    {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  end

  defp body_error(limits),
    do: {:error, {:io, "Response body is larger than #{limits.max_body} bytes"}}

  @doc false
  # The cause of a request ended at its total time limit.
  @spec total_error() :: String.t()
  def total_error, do: "Request did not complete within its total time limit"

  # A read or connect waits its own timeout (0: none) but never past the total time limit.
  defp wait(ms, ends) do
    left = max(ends - now(), 0)
    if ms == 0, do: left, else: min(ms, left)
  end

  defp over?(ends), do: now() >= ends

  defp now, do: System.monotonic_time(:millisecond)
end
