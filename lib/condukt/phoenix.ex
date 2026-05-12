defmodule Condukt.Phoenix do
  @moduledoc """
  Phoenix router helpers for typed Condukt operations.

  Import `operation_route/3` inside a Phoenix router to expose an operation as
  a JSON POST endpoint:

      import Condukt.Phoenix, only: [operation_route: 3, operation_route: 4]

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

  @doc false
  def init(action), do: action

  @doc false
  def call(conn, :operation), do: operation(conn, conn.params)

  @doc false
  def operation(conn, _params) do
    conn
    |> Map.fetch!(:private)
    |> Map.fetch!(:condukt_operation)
    |> then(&Condukt.Plug.call(conn, &1))
  end
end
