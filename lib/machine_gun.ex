defmodule MachineGun do
  alias MachineGun.{Supervisor, Worker}

  @pool_timeout 1000

  defmodule Response do
    defstruct [
      :request_url,
      :status_code,
      :headers,
      :body
    ]
  end

  defmodule Request do
    defstruct [
      :method,
      :path,
      :headers,
      :body,
      :opts
    ]
  end

  defmodule Error do
    defexception reason: nil
    def message(%__MODULE__{reason: reason}), do: inspect(reason)
  end

  def get(url, headers \\ [], opts \\ %{}) do
    request("GET", url, "", headers, opts)
  end

  def post(url, body, headers \\ [], opts \\ %{}) do
    request("POST", url, body, headers, opts)
  end

  def put(url, body, headers \\ [], opts \\ %{}) do
    request("PUT", url, body, headers, opts)
  end

  def delete(url, headers \\ [], opts \\ %{}) do
    request("DELETE", url, "", headers, opts)
  end

  def get!(url, headers \\ [], opts \\ %{}) do
    request!("GET", url, "", headers, opts)
  end

  def post!(url, body, headers \\ [], opts \\ %{}) do
    request!("POST", url, body, headers, opts)
  end

  def put!(url, body, headers \\ [], opts \\ %{}) do
    request!("PUT", url, body, headers, opts)
  end

  def delete!(url, headers \\ [], opts \\ %{}) do
    request!("DELETE", url, "", headers, opts)
  end

  def request!(method, url, body \\ "", headers \\ [], opts \\ %{}) do
    case request(method, url, body, headers, opts) do
      {:ok, response} -> response
      {:error, %Error{reason: reason}} -> raise Error, reason: reason
    end
  end

  def request(method, url, body \\ "", headers \\ [], opts \\ %{})
    when is_binary(url)
    and is_list(headers)
    and is_map(opts)  do
    case URI.parse(url) do
      %URI{
        scheme: scheme,
        host: host,
        path: path,
        port: port,
        query: query} when is_binary(host)
        and is_integer(port) ->
        pool_group = opts |> Map.get(:pool_group, :default)
        pool = "#{pool_group}@#{host}:#{port}" |> String.to_atom()
        path = if path != nil do
          path
        else
          "/"
        end
        path = if query != nil do
          "#{path}?#{query}"
        else
          path
        end
        headers = headers
          |> Enum.map(fn
            {name, value} when is_integer(value) ->
              {name, Integer.to_string(value)}
            {name, value} ->
              {name, value}
          end)
        method = case method do
          :get -> "GET"
          :post -> "POST"
          :put -> "PUT"
          :delete -> "DELETE"
          s when is_binary(s) -> s
        end
        request = %Request{
          method: method,
          path: path,
          headers: headers,
          body: body,
          opts: opts
        }
        try do
          do_request(pool, url, request)
        catch
          :exit, {:noproc, _} ->
            pool_opts = Application.get_env(:machine_gun, pool_group, %{})
            :ok = ensure_pool(pool, pool_opts, scheme, host, port)
            do_request(pool, url, request)
        end
      _ ->
        {:error, %Error{reason: :bad_url}}
    end
  end

  defp ensure_pool(pool, opts, scheme, host, port) do
    r = case scheme do
      "http"  -> {:ok, :tcp, [:http]}
      "https" -> {:ok, :ssl, [:http2, :http]}
      _ -> {:error, %Error{reason: :bad_url_scheme}}
    end
    case r do
      {:ok, transport, protocols} ->
        conn_opts = opts |> Map.get(:conn_opts, %{})
        conn_opts = %{
          retry: 0,
          http_opts: %{keepalive: :infinity},
          protocols: protocols,
          transport: transport}
          |> Map.merge(conn_opts)
        opts = opts |> Map.merge(%{conn_opts: conn_opts})
        case Supervisor.start(
          pool,
          host,
          port,
          opts) do
          {:ok, _} ->
            :ok
          {:error, {:already_started, _}} ->
            :ok
          error ->
            error
        end
      error ->
        error
    end
  end

  defp do_request(
    pool,
    url,
    %Request{
      method: method,
      path: path,
      opts: opts} = request) do
    pool_timeout = opts |> Map.get(:pool_timeout, @pool_timeout)
    m_mod = Application.get_env(:machine_gun, :metrics_mod)
    m_state = if m_mod != nil, do: m_mod.queued(
      pool, :poolboy.status(pool), method, path)
    try do
      case :poolboy.transaction(pool, fn worker ->
        Worker.request(worker, request, m_mod, m_state)
      end, pool_timeout) do
        {:ok, response} ->
          {:ok, %Response{response |
            request_url: url
          }}
        error ->
          error
      end
    catch
      :exit, {:timeout, _} ->
        if m_state != nil, do: m_mod.queue_timeout(m_state)
        {:error, %Error{reason: :pool_timeout}}
      :exit, {{:shutdown, error}, _} ->
        {:error, %Error{reason: error}}
    end
  end
end