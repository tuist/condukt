defmodule Condukt.Sandbox.Net.Rule.AllowHosts do
  @moduledoc """
  `Condukt.Sandbox.Net.Rule` that returns `:allow` when the request
  host matches one of the configured glob patterns, and `:continue`
  otherwise.

  Configured with a list of patterns under the `:hosts` opt. Patterns
  follow the glob syntax documented in `Condukt.Sandbox.Net.Hosts`:
  `*` matches a single DNS label, `**` matches one or more labels.

      {Condukt.Sandbox.Net.Rule.AllowHosts, hosts: ["api.github.com", "*.openai.com"]}
  """

  @behaviour Condukt.Sandbox.Net.Rule

  alias Condukt.Sandbox.Net.Hosts

  @impl true
  def evaluate(_context, %{host: host}, opts) do
    hosts = Keyword.get(opts, :hosts, [])
    if Hosts.matches_any?(host, hosts), do: :allow, else: :continue
  end
end
