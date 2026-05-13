defmodule Condukt.AgentRuntime do
  @moduledoc """
  Behaviour for runtimes that own an agent's inner execution loop.

  Native Condukt agents use `Condukt.AgentRuntimes.Native`, where
  `Condukt.Session` drives ReqLLM turns and Condukt tool calls. Runtime modules
  that implement this behaviour receive the user prompt, a Condukt-owned
  context map, and per-run options. They return either a final text response or
  an explicit result map.
  """

  @type context :: %{
          required(:agent) => pid(),
          required(:agent_module) => module(),
          required(:session_id) => String.t(),
          required(:cwd) => String.t(),
          required(:sandbox) => struct(),
          required(:secrets) => map(),
          required(:instructions) => String.t() | nil,
          required(:system_prompt) => String.t() | nil,
          required(:project_context) => map(),
          required(:runtime_opts) => keyword(),
          required(:assigns) => map(),
          required(:user_state) => term()
        }

  @type result ::
          String.t()
          | %{
              optional(:response) => String.t(),
              optional(:messages) => [struct()],
              optional(:assigns) => map()
            }

  @callback run(String.t(), context(), keyword()) :: {:ok, result()} | {:error, term()}
end
