defmodule Condukt.Sandbox.NetworkPolicy.AgentDecider do
  @moduledoc """
  `Condukt.Sandbox.NetworkPolicy.Decider` implementation that delegates to a
  `Condukt`-defined agent module.

  Use this when you want the decision to come from a model with the
  session context in front of it:

      %Condukt.Sandbox.NetworkPolicy{
        decide: {Condukt.Sandbox.NetworkPolicy.AgentDecider, agent: MyApp.NetGuard}
      }

  Required option:

    * `:agent` — a module that `use`s `Condukt` (or is a runnable
      Condukt agent). Must declare an output schema with `decision`
      (`"allow" | "deny"`) and `reason` (`string`) fields.

  Optional options:

    * `:api_key` / `:base_url` / `:model` / `:system_prompt` — passed
      to `Condukt.run/3`, override the agent module's declared values.
    * `:context_keys` — list of context-snapshot keys to render into
      the prompt. Defaults to `[:recent_messages, :request, :metadata]`.

  ## Loop avoidance

  The decider agent's own outbound traffic does NOT route through the
  gated session's policy. Configure the decider agent with its own
  `:net` policy (or with `:net` unset) so its API calls reach the
  model provider without going through the same gate they decide on.
  """

  @behaviour Condukt.Sandbox.NetworkPolicy.Decider

  alias Condukt.Sandbox.NetworkPolicy.Context
  alias Condukt.Sandbox.NetworkPolicy.Request

  @impl true
  def decide(%Context{} = context, %Request{} = request, opts) do
    agent = Keyword.fetch!(opts, :agent)
    run_opts = Keyword.drop(opts, [:agent, :context_keys])

    prompt = render_prompt(context, request, opts)

    case Condukt.run(agent, prompt, run_opts) do
      {:ok, %{result: result}} -> parse_decision(result)
      {:ok, result} -> parse_decision(result)
      {:error, reason} -> {:deny, {:decider_error, reason}}
    end
  end

  defp render_prompt(context, request, opts) do
    keys = Keyword.get(opts, :context_keys, [:recent_messages, :request, :metadata])

    payload = %{
      session_id: context.session_id,
      recent_messages: if(:recent_messages in keys, do: context.recent_messages, else: []),
      request: if(:request in keys, do: serialise_request(request), else: %{}),
      metadata: if(:metadata in keys, do: context.metadata, else: %{})
    }

    JSON.encode!(payload)
  end

  defp serialise_request(%Request{} = request) do
    %{
      method: request.method,
      host: request.host,
      port: request.port,
      path: request.path,
      scheme: request.scheme,
      request_headers: request.request_headers
    }
  end

  defp parse_decision(%{"decision" => "allow"}), do: :allow

  defp parse_decision(%{"decision" => "deny"} = result) do
    {:deny, Map.get(result, "reason", "denied by decider agent")}
  end

  defp parse_decision(%{decision: "allow"}), do: :allow

  defp parse_decision(%{decision: "deny"} = result) do
    {:deny, Map.get(result, :reason, "denied by decider agent")}
  end

  defp parse_decision(binary) when is_binary(binary) do
    case JSON.decode(binary) do
      {:ok, json} -> parse_decision(json)
      {:error, _} -> {:deny, :decider_unparseable}
    end
  end

  defp parse_decision(_other), do: {:deny, :decider_unparseable}
end
