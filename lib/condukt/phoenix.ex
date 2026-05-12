defmodule Condukt.Phoenix do
  @moduledoc """
  Phoenix router helpers for Condukt agents and typed operations.

  Import `agent_route/2` or `operation_route/3` inside a Phoenix router to
  expose a JSON POST endpoint:

      import Condukt.Phoenix, only: [agent_route: 2, agent_route: 3, operation_route: 3, operation_route: 4]

      agent_route "/assistant", MyApp.AssistantAgent, prompt: "Help with this request."
      operation_route "/review-pr", MyApp.ReviewAgent, :review_pr,
        run_opts: [timeout: 120_000]

  The macro expands to a Phoenix controller-style route whose action delegates
  to `Condukt.Plug`, so the request and response shapes match the Plug
  integration.
  """

  @doc """
  Declares a Phoenix POST route for an operation.
  """
  defmacro operation_route(path, agent_module, operation_name, opts \\ []) do
    plug_opts =
      opts
      |> Keyword.put(:operation, operation_name)
      |> Keyword.put(:agent, agent_module)

    quote do
      post(unquote(path), Condukt.Phoenix, :operation, private: %{condukt_operation: unquote(plug_opts)})
    end
  end

  @doc """
  Declares a Phoenix POST route for a module-defined one-shot agent.
  """
  defmacro agent_route(path, agent_module, opts \\ []) do
    plug_opts = Keyword.put(opts, :agent, agent_module)

    quote do
      post(unquote(path), Condukt.Phoenix, :agent, private: %{condukt_route: unquote(plug_opts)})
    end
  end

  @doc false
  def init(action), do: action

  @doc false
  def call(conn, :agent), do: agent(conn, conn.params)

  @doc false
  def call(conn, :operation), do: operation(conn, conn.params)

  @doc false
  def agent(conn, _params), do: call_plug(conn)

  @doc false
  def operation(conn, _params), do: call_plug(conn)

  defp call_plug(conn) do
    conn
    |> Map.fetch!(:private)
    |> fetch_route_opts()
    |> then(&Condukt.Plug.call(conn, &1))
  end

  defp fetch_route_opts(private) do
    Map.get_lazy(private, :condukt_route, fn ->
      Map.fetch!(private, :condukt_operation)
    end)
  end
end
