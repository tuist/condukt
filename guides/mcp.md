# Model Context Protocol

Condukt agents and workflows can talk to external [Model Context
Protocol](https://modelcontextprotocol.io) servers and call the tools
those servers expose alongside their own statically defined tools.

The `Condukt.MCP` namespace ships a client-only implementation. Three
transports are supported:

* `stdio`: spawns a subprocess and exchanges newline-delimited
  JSON-RPC over its stdin/stdout. Most local MCP servers ship as
  binaries that speak this transport.
* `http_sse`: the legacy 2024-11 HTTP+SSE transport. A long-lived
  `text/event-stream` GET on the configured URL receives responses,
  and an SSE `endpoint` event tells the client where to POST requests.
* `streamable_http`: the 2025-03-26 Streamable HTTP transport. A
  single endpoint URL accepts POSTs that return either a JSON-RPC
  response inline or a `text/event-stream` body containing one or
  more events. New HTTP-based MCP servers should target this transport.

## Declaring servers on an agent

Add the optional `mcp_servers/0` callback to a module that uses
`Condukt`. Each entry is a `Condukt.MCP.Server` struct:

```elixir
defmodule MyApp.Agent do
  use Condukt

  @impl true
  def tools do
    [Condukt.Tools.Read, Condukt.Tools.Bash]
  end

  @impl true
  def mcp_servers do
    [
      %Condukt.MCP.Server{
        name: "github",
        transport: {:stdio, command: "github-mcp-server", args: []},
        env: ["GITHUB_TOKEN"]
      },
      %Condukt.MCP.Server{
        name: "linear",
        transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
        auth: {:bearer, {:env, "LINEAR_API_KEY"}}
      }
    ]
  end
end
```

The session opens one `Condukt.MCP.Client` per server at startup,
fetches each server's `tools/list`, and merges the discovered tools
into the agent's tool list under their `<server>.<tool>` ids
(`github.create_issue`, `linear.list_issues`, ...). When the model
calls `linear.list_issues`, Condukt routes the call as a JSON-RPC
`tools/call` request to the Linear server and surfaces the response
to the model.

Servers can also be supplied per-call:

```elixir
{:ok, response} =
  Condukt.run("Open a draft PR for the sandbox refactor.",
    model: "anthropic:claude-sonnet-4-6",
    mcp_servers: [github_server],
    tools: [Condukt.Tools.Read]
  )
```

## Declaring servers in HCL workflows

Workflows declare servers with top-level `mcp_server` blocks. Tool
steps and agent steps reference their tools by the same prefixed id:

```hcl
workflow "review_issue" {
  input "issue_id" {
    type = "string"
  }

  mcp_server "linear" {
    transport = "streamable_http"
    url       = "https://mcp.linear.app/mcp"
    auth      = { type = "bearer", env = "LINEAR_API_KEY" }
  }

  tool "issue" {
    id   = "linear.get_issue"
    args = { issue_id = "${input.issue_id}" }
  }

  agent "draft" {
    needs = ["issue"]
    model = "anthropic:claude-sonnet-4-6"
    tools = ["linear.add_comment"]
    input = "Comment on the issue with a summary:\n\n${task.issue.output}"
  }

  output = task.draft.output
}
```

The executor opens the configured servers when `Condukt.Workflows.run/3`
starts and closes them when the run finishes (including on error).

### HCL attributes

Every `mcp_server` block has a required `transport` attribute. The
remaining attributes depend on the transport.

| Transport         | Required          | Optional                                    |
|-------------------|-------------------|---------------------------------------------|
| `stdio`           | `command`         | `args`, `env`, `prefix`, `init_timeout`, `request_timeout` |
| `http_sse`        | `url`             | `headers`, `auth`, `prefix`, `init_timeout`, `request_timeout` |
| `streamable_http` | `url`             | `headers`, `auth`, `prefix`, `init_timeout`, `request_timeout` |
| `http`            | alias for `streamable_http` |

`auth` is an HCL object literal: `auth = { type = "bearer", env = "LINEAR_API_KEY" }`.
`env` is a list of variable names that should be passed through to the
spawned subprocess from the parent's environment.

## Authentication

The library supports two HTTP authentication modes declared on the
server:

```elixir
# Static or env-resolved bearer token
auth: {:bearer, {:env, "LINEAR_API_KEY"}}
auth: {:bearer, {:static, "literal-test-token"}}
auth: {:bearer, {:op, "op://Engineering/Linear/token"}}

# OAuth 2.0 client credentials grant
auth:
  {:client_credentials,
   token_url: "https://auth.example.com/oauth/token",
   client_id_env: "MCP_CLIENT_ID",
   client_secret_env: "MCP_CLIENT_SECRET",
   scope: "mcp.read mcp.call"}
```

Bearer secret refs use the same shapes accepted by `Condukt.Secrets`:
`{:env, NAME}`, `{:static, VALUE}`, `{:op, REF}`, or `{module, opts}`
for a custom `Condukt.SecretProvider`.

Interactive OAuth flows that require a browser are intentionally not
supported. Resolve such tokens out of band, for example through a
separate one-time CLI login that writes the resulting refresh or
access token into your secret store, and reference the resulting value
through the bearer or client_credentials shapes above.

For stdio servers `auth` is unused. Credentials flow into the
subprocess as environment variables declared on the server's `env`
field:

```elixir
env: ["GITHUB_TOKEN", "GITHUB_API_URL"]              # passthrough from parent
env: %{"GH_TOKEN" => {:env, "GITHUB_TOKEN"}}          # rename
env: %{"GH_TOKEN" => {:static, "ghp_local"}}          # literal
```

Resolved bearer tokens are stored on the in-memory transport and used
as `Authorization: Bearer <token>` headers on every outgoing request.
If you want them redacted from session transcripts and tool result
snapshots, declare them in `:secrets` as well:

```elixir
secrets: [LINEAR_API_KEY: {:env, "LINEAR_API_KEY"}]
```

`Condukt.Secrets` then exact-match redacts the value from outbound
messages and stored tool results.

## Tool naming

By default each tool is exposed under `<server_name>.<tool_name>`.
Override with the `:prefix` field on the server:

```elixir
%Condukt.MCP.Server{name: "github", transport: ..., prefix: "gh"}
# tools: gh.create_issue, gh.list_pull_requests, ...
```

Set `prefix: ""` to expose tools under their bare server names. Use
this only when you control every server name and can rule out
collisions.

## Sandbox interaction

Stdio MCP servers are user-configured external binaries that Condukt
spawns as part of session setup. They are not routed through
`Condukt.Sandbox` for the same reason `Condukt.Tools.Command` is
exempt: the binary is selected by the operator, not by the model.
HTTP and streamable HTTP transports issue plain HTTP requests through
Req and have nothing to sandbox.

If you need stronger isolation, run the MCP server inside a container
or under a process supervisor that enforces the constraints you need,
and point the `:command` at the container entrypoint.

## Lifecycle and supervision

`Condukt.MCP.Client` is a `GenServer` linked to the session that
declared its server. When the session terminates, every client it
opened terminates too: stdio subprocesses receive EOF on stdin and
shut down, and HTTP transports close their open requests.

Workflows follow the same pattern. `Condukt.Workflows.run/3` opens
clients before the first step and closes them after the last step,
including in error paths.

A client that loses its connection mid-run does not restart in v1.
Outstanding tool calls fail with `{:error, {:transport_down, _}}` and
the session continues. Future iterations may add a per-server restart
policy.
