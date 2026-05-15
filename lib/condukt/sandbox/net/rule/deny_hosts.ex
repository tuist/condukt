defmodule Condukt.Sandbox.Net.Rule.DenyHosts do
  @moduledoc """
  `Condukt.Sandbox.Net.Rule` that returns `{:deny, :matched_deny_list}`
  when the request host matches one of the configured glob patterns,
  and `:continue` otherwise.

      {Condukt.Sandbox.Net.Rule.DenyHosts, hosts: ["*.internal.example.com"]}
  """

  @behaviour Condukt.Sandbox.Net.Rule

  alias Condukt.Sandbox.Net.Hosts

  @impl true
  def evaluate(_context, %{host: host}, opts) do
    hosts = Keyword.get(opts, :hosts, [])
    if Hosts.matches_any?(host, hosts), do: {:deny, :matched_deny_list}, else: :continue
  end
end
