defmodule Absinthe.Plug.GraphiQL do
  @moduledoc """
  Provides a GraphiQL interface.

  ## Examples

  Serve the GraphiQL "advanced" interface at `/graphiql`, but only in
  development:

      if Mix.env == :dev do
        forward "/graphiql",
          to: Absinthe.Plug.GraphiQL,
          init_opts: [schema: MyApp.Schema]
      end

  Use the "simple" interface (original GraphiQL) instead:

      if Mix.env == :dev do
        forward "/graphiql",
          to: Absinthe.Plug.GraphiQL,
          init_opts: [
            schema: MyApp.Schema,
            interface: :simple
          ]

  ## Interface Selection

  The GraphiQL interface can be switched using the `:interface` option.

  - `:advanced` (default) will serve the [GraphiQL Workspace](https://github.com/OlegIlyenko/graphiql-workspace) interface from Oleg Ilyenko.
  - `:simple` will serve the original [GraphiQL](https://github.com/graphql/graphiql) interface from Facebook.

  See `Absinthe.Plug` for the other  options.

  ## Default Headers

  You can optionally provide default headers if the advanced interface (GraphiQL Workspace) is selected.
  Note that you may have to clean up your existing workspace by clicking the trashcan icon in order to see the newly set default headers.

      forward "/graphiql",
        to: Absinthe.Plug.GraphiQL,
        init_opts: [
          schema: MyApp.Schema,
          default_headers: {__MODULE__, :graphiql_headers}
        ]

      def graphiql_headers do
        %{
          "X-CSRF-Token" => Plug.CSRFProtection.get_csrf_token(),
          "X-Foo" => "Bar"
        }
      end

  ## Default URL

  You can also optionally set the default URL to be used for sending the queries to. This only applies to the advanced interface (GraphiQL Workspace).

      forward "/graphiql",
        to: Absinthe.Plug.GraphiQL,
        init_opts: [
          schema: MyApp.Schema,
          default_url: "https://api.mydomain.com/graphql"
        ]
  """

  require EEx
  EEx.function_from_file :defp, :graphiql_html, Path.join(__DIR__, "graphiql.html.eex"),
    [:query_string, :variables_string, :result_string, :socket_url, :assets]

  EEx.function_from_file :defp, :graphiql_workspace_html, Path.join(__DIR__, "graphiql_workspace.html.eex"),
    [:query_string, :variables_string, :default_headers, :default_url, :assets]

  @behaviour Plug

  import Plug.Conn

  @type opts :: [
    schema: atom,
    adapter: atom,
    path: binary,
    context: map,
    json_codec: atom | {atom, Keyword.t},
    interface: :advanced | :simple,
    default_headers: {module, atom},
    default_url: binary,
    assets: Keyword.t,
    socket: module,
    socket_url: binary,
  ]

  @doc false
  @spec init(opts :: opts) :: map
  def init(opts) do
    assets = Absinthe.Plug.GraphiQL.Assets.get_assets(:local)

    opts
    |> Absinthe.Plug.init
    |> Map.put(:interface, Keyword.get(opts, :interface) || :advanced)
    |> Map.put(:default_headers, Keyword.get(opts, :default_headers))
    |> Map.put(:default_url, Keyword.get(opts, :default_url))
    |> Map.put(:assets, assets)
    |> Map.put(:socket, Keyword.get(opts, :socket))
    |> Map.put(:socket_url, Keyword.get(opts, :socket_url))
  end

  @doc false
  def call(conn, config) do
    case html?(conn) do
      true -> do_call(conn, config)
      _ -> Absinthe.Plug.call(conn, config)
    end
  end

  defp html?(conn) do
    Plug.Conn.get_req_header(conn, "accept")
    |> List.first
    |> case do
      string when is_binary(string) ->
        String.contains?(string, "text/html")
      _ ->
        false
    end
  end

  defp do_call(conn, %{json_codec: json_codec, interface: interface} = config) do
    config = case config[:default_headers] do
        nil -> Map.put(config, :default_headers, "[]")
        {module, fun} when is_atom(fun) ->
          header_string =
            apply(module, fun, [])
            |> Enum.map(fn {k, v} -> %{"name" => k, "value" => v} end)
            |> json_codec.module.encode!(pretty: true)

          Map.put(config, :default_headers, header_string)
        val ->
          raise "invalid default headers: #{inspect val}"
      end

    with {:ok, conn, request} <- Absinthe.Plug.Request.parse(conn, config),
         {:process, request} <- select_mode(request),
         {:ok, request} <- Absinthe.Plug.ensure_processable(request, config),
         :ok <- Absinthe.Plug.Request.log(request, config.log_level) do

      conn_info = %{
        conn_private: (conn.private[:absinthe] || %{}) |> Map.put(:http_method, conn.method),
      }

      case Absinthe.Plug.run_request(request, conn_info, config) do
        {:ok, result} ->
          query = hd(request.queries) # GraphiQL doesn't batch requests, so the first query is the only one
          {:ok, conn, result, query.variables, query.document || ""}
        {:error, {:http_method, _}, _} ->
          query = hd(request.queries)
          {:http_method_error, query.variables, query.document || ""}
        other -> other
      end
    end
    |> case do
      {:ok, conn, result, variables, query} ->
        query = query |> js_escape

        var_string = variables
        |> config.json_codec.module.encode!(pretty: true)
        |> js_escape


        result = result
        |> config.json_codec.module.encode!(pretty: true)
        |> js_escape

        config = %{
          query: query,
          var_string: var_string,
          result: result,
        } |> Map.merge(config)

        conn
        |> render_interface(interface, config)

      {:input_error, msg} ->
        conn
        |> send_resp(400, msg)

      :start_interface ->

        conn
        |> render_interface(interface, config)

      {:http_method_error, variables, query} ->
        query = query |> js_escape

        var_string =
          variables
          |> config.json_codec.module.encode!(pretty: true)
          |> js_escape

        config = %{
          query: query,
          var_string: var_string,
        } |> Map.merge(config)

        conn
        |> render_interface(interface, config)

      {:error, error, _} when is_binary(error) ->
        conn
        |> send_resp(500, error)

    end
  end

  @spec select_mode(request :: Absinthe.Plug.Request.t) :: :start_interface | {:process, Absinthe.Plug.Request.t}
  defp select_mode(%{queries: [%Absinthe.Plug.Request.Query{document: nil}]}), do: :start_interface
  defp select_mode(request), do: {:process, request}

  defp find_socket_path(endpoint, socket) do
    endpoint.__sockets__
    |> Enum.find(fn {_, module} ->
      module == socket
    end)
    |> case do
      {path, _} -> {:ok, path}
      _ -> :error
    end
  end

  @render_defaults %{query: "", var_string: "", results: ""}

  @spec render_interface(conn :: Conn.t, interface :: :advanced | :simple, opts :: Keyword.t) :: Conn.t
  defp render_interface(conn, interface, opts)
  defp render_interface(conn, :simple, opts) do
    opts = Map.merge(@render_defaults, opts)

    opts = with \
      {:ok, socket} <- Map.fetch(opts, :socket),
      %{private: %{phoenix_endpoint: endpoint}} <- conn,
      {:ok, socket_path} <- find_socket_path(endpoint, socket) do
        socket_url = "`${protocol}//${window.location.host}#{socket_path}`"
        Map.put(opts, :socket_url, socket_url)
      else
        _ ->
          opts
      end

    graphiql_html(
      opts[:query], opts[:var_string], opts[:result], opts[:socket_url], opts[:assets]
    )
    |> rendered(conn)
  end
  defp render_interface(conn, :advanced, opts) do
    opts = Map.merge(@render_defaults, opts)
    graphiql_workspace_html(
      opts[:query], opts[:var_string], opts[:default_headers],
      default_url(opts[:default_url]), opts[:assets]
    )
    |> rendered(conn)
  end

  defp default_url(nil), do: "window.location.origin + window.location.pathname"
  defp default_url(url), do: "'#{url}'"

  @spec rendered(String.t, Plug.Conn.t) :: Conn.t
  defp rendered(html, conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp js_escape(string) do
    string
    |> String.replace(~r/\n/, "\\n")
    |> String.replace(~r/'/, "\\'")
  end
end
