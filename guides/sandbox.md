# Sandbox

A sandbox is a runtime-swappable backend for the operations a tool needs to
reach the outside world: read or write files, run shell commands, glob files,
search file contents. Built-in tools like `Condukt.Tools.Read` and
`Condukt.Tools.Bash` declare one tool name and JSON schema to the LLM and
route every primitive call through the active sandbox. The same agent
definition can therefore run against the host filesystem in development and
against an isolated virtual filesystem in production by changing one option
at session start.

## Built-in sandboxes

* `Condukt.Sandbox.Local` is the default. It operates against the host
  filesystem and spawns real bash subprocesses via `MuonTrap`.
* `Condukt.Sandbox.Virtual` runs against an in-memory virtual filesystem and
  a Rust-implemented bash interpreter (bashkit), with no host process
  spawning by default. It is shipped via a precompiled NIF, so consumers
  do not need a Rust toolchain to use it.
* `Condukt.Sandbox.Kubernetes` runs each session inside a dedicated
  Kubernetes pod. All filesystem reads, writes, and process execution
  happen inside the pod via the Kubernetes exec API; the agent cannot
  reach the host running the Condukt BEAM process.

Custom sandboxes implement the `Condukt.Sandbox` behaviour and plug in the
same way.

## Virtual sandbox

`Condukt.Sandbox.Virtual` is backed by [bashkit](https://github.com/everruns/bashkit),
a virtual bash interpreter with an in-memory filesystem written in Rust. It
is loaded into the BEAM via a Rustler NIF.

```elixir
# Empty in-memory filesystem.
{:ok, sb} = Condukt.Sandbox.new(Condukt.Sandbox.Virtual)
{:ok, %{output: "hi\n", exit_code: 0}} = Condukt.Sandbox.exec(sb, "echo hi")

# Mount the host project at /workspace, read-only:
{:ok, sb} =
  Condukt.Sandbox.new(Condukt.Sandbox.Virtual,
    mounts: [{File.cwd!(), "/workspace", :readonly}]
  )

{:ok, contents} = Condukt.Sandbox.read(sb, "/workspace/mix.exs")

# Or mount at runtime:
:ok = Condukt.Sandbox.mount(sb, "/path/on/host", "/extra")
```

Each `exec/3` call is stateless: `cd`, `export`, and shell variables do
not persist across calls. This matches `Sandbox.Local`'s contract and
lets the `Condukt.Tools.Bash` tool behave identically in both sandboxes.

The precompiled NIF is built and attached to GitHub releases for the
following targets:

```
aarch64-apple-darwin
aarch64-unknown-linux-gnu
x86_64-apple-darwin
x86_64-pc-windows-msvc
x86_64-unknown-linux-gnu
```

Compile in `MIX_ENV=dev` (and have a Rust toolchain installed) to build the
NIF from source. Other Mix environments download the precompiled artifact.
The release workflow publishes from `MIX_ENV=prod`, so package validation uses
the same precompiled path as Hex consumers.

### Sandbox-specific tools

`Condukt.Sandbox.Virtual.Tools.Mount` lets the agent mount a host
directory into the virtual filesystem at runtime. It only makes sense
with the Virtual sandbox; against `Sandbox.Local` it returns a clear
"not supported" error.

```elixir
def tools do
  Condukt.Tools.coding_tools() ++ [Condukt.Sandbox.Virtual.Tools.Mount]
end
```

## Kubernetes sandbox

`Condukt.Sandbox.Kubernetes` creates one pod per session and routes every
filesystem and process primitive through the Kubernetes exec API. It uses
the [`:k8s`](https://hex.pm/packages/k8s) library and talks to the API
server over HTTPS, so no `kubectl` binary is required.

```elixir
# Minimal: uses the current kubeconfig context and the "default" namespace.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: Condukt.Sandbox.Kubernetes
  )

# Production: pinned image, namespace, resource limits, RBAC.
sandbox = {
  Condukt.Sandbox.Kubernetes,
  image: "ghcr.io/myorg/agent-runtime:v1.4.2",
  namespace: "agents",
  context: "prod-cluster",
  service_account: "condukt-agent",
  resources: %{
    requests: %{cpu: "500m", memory: "1Gi"},
    limits: %{cpu: "2", memory: "4Gi"}
  },
  active_deadline_seconds: 4 * 3600,
  labels: %{"tenant" => "acme"},
  cwd: "/workspace"
}
```

### Decoupled pod lifecycle with `:id`

The Kubernetes sandbox supports an idempotent `:id` opt that decouples the
pod lifecycle from any single BEAM process. `init/1` derives a deterministic
pod name from the id and either adopts an existing pod or creates a fresh
one. This is the recommended pattern when an Oban-style worker manages the
session: a job retry passes the same `session_id` through, the sandbox
reattaches to the existing pod, and any state already on disk (a cloned
repo, in-progress edits) is preserved.

```elixir
defmodule MyApp.AgentWorker do
  use Oban.Worker, queue: :agents, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"session_id" => sid, "prompt" => prompt}}) do
    {:ok, agent} =
      MyApp.CodingAgent.start_link(
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        sandbox: {Condukt.Sandbox.Kubernetes, id: sid, namespace: "agents"}
      )

    Condukt.Session.run(agent, prompt)
  end
end
```

When `:id` is supplied, `shutdown/1` is a no-op by default and the pod
outlives the BEAM process. When the session is truly done, the caller
deletes the pod explicitly:

```elixir
Condukt.Sandbox.Kubernetes.terminate(session_id, namespace: "agents")
```

When `:id` is omitted, a UUID is generated and `shutdown/1` deletes the
pod.

### State persistence

Each pod gets an `emptyDir` volume mounted at the session cwd
(`/workspace` by default). With `restartPolicy: Always`, K8s restarts the
container on crash and the volume survives, so a cloned repo or
in-progress file edits persist across container restarts within the same
pod. The volume does not survive pod deletion or node loss; for cross-node
durability, build an image that mounts a PersistentVolumeClaim.

### Stale pod handling

When `init/1` adopts an existing pod, it accepts `Running`, waits on
`Pending`, and waits for terminating pods to be deleted before recreating.
On `Succeeded` or `Failed` (which the keepalive container should not
normally produce) it returns `{:error, {:stale_pod, phase}}` by default
so the caller can decide what to do. Pass `on_stale: :recreate` to delete
and recreate automatically.

### Hard ceiling on pod lifetime

Every pod is created with `activeDeadlineSeconds` (default 8 hours).
This is K8s-side insurance against truly abandoned pods: even if Condukt
crashes and forgets the pod, the cluster reclaims it.

### Auth resolution

Connection auth is resolved in this order:

1. The `:conn` opt, if you build a `K8s.Conn` yourself.
2. The in-cluster ServiceAccount token at
   `/var/run/secrets/kubernetes.io/serviceaccount/` when
   `KUBERNETES_SERVICE_HOST` is set or `in_cluster: true` is passed.
3. A kubeconfig file at `:kubeconfig` (or `$KUBECONFIG`, or
   `~/.kube/config`), using `:context` if supplied.

### RBAC

The identity Condukt runs as needs permission to create, get, exec into,
and delete pods in the target namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: condukt-sandbox
  namespace: agents
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: condukt-sandbox
  namespace: agents
subjects:
  - kind: ServiceAccount
    name: condukt
    namespace: agents
roleRef:
  kind: Role
  name: condukt-sandbox
  apiGroup: rbac.authorization.k8s.io
```

### Limitations

* `mount/3` is unsupported. K8s pods cannot accept new volumes once
  running. Mounts must be declared up front; in v1 that means baking a
  PVC into a custom image.
* Writes are base64-embedded in the exec command line, so very large
  payloads (tens of MB) should be fetched into the pod from inside it
  (`git clone`, `curl`, etc) rather than written through `Sandbox.write/3`.

## Picking a sandbox

Sessions resolve the sandbox in this order:

1. The `:sandbox` option passed to `start_link/1`.
2. The agent module's `sandbox/0` callback, if defined.
3. Default: `{Condukt.Sandbox.Local, cwd: <:cwd option or File.cwd!()>}`.

```elixir
# Default: Local sandbox rooted at the host cwd.
{:ok, agent} = MyApp.CodingAgent.start_link(api_key: "...")

# Local sandbox rooted at a specific directory.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: {Condukt.Sandbox.Local, cwd: "/path/to/project"}
  )

# Virtual sandbox (when condukt_bashkit_nif is installed).
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: Condukt.Sandbox.Virtual
  )
```

Or declare a default on the agent module:

```elixir
defmodule MyApp.CodingAgent do
  use Condukt

  @impl true
  def sandbox do
    {Condukt.Sandbox.Local, cwd: "/path/to/project"}
  end
end
```

## Sandbox-aware tools

If you write a custom tool that touches the filesystem or spawns processes,
route through the `Condukt.Sandbox.*` facade rather than calling `File.*`,
`System.cmd/3`, or `MuonTrap.cmd/3` directly. Direct calls bypass the
sandbox and break the ability to swap one in.

The facade:

```elixir
Condukt.Sandbox.read(sandbox, path)
Condukt.Sandbox.write(sandbox, path, content)
Condukt.Sandbox.edit(sandbox, path, old_text, new_text)
Condukt.Sandbox.exec(sandbox, command, opts)
Condukt.Sandbox.glob(sandbox, pattern, opts)
Condukt.Sandbox.grep(sandbox, pattern, opts)
Condukt.Sandbox.mount(sandbox, host_path, vfs_path)
```

The sandbox is in `context.sandbox` when your tool's `call/2` is invoked.
See the [Tools guide](tools.md) for an example.

## Writing a custom sandbox

Implement the `Condukt.Sandbox` behaviour. `init/1` builds the per-session
state, `shutdown/1` releases it, and the rest are I/O primitives:

```elixir
defmodule MyApp.S3Sandbox do
  @behaviour Condukt.Sandbox

  @impl true
  def init(opts), do: {:ok, %{bucket: opts[:bucket]}}

  @impl true
  def shutdown(_state), do: :ok

  @impl true
  def read_file(state, path), do: ExAws.S3.get_object(state.bucket, path) |> ExAws.request()

  # write_file/3, edit_file/4, exec/3, plus optional glob/3, grep/3, mount/3
end
```

`glob/3`, `grep/3`, and `mount/3` are optional callbacks. The facade returns
`{:error, :not_supported}` when a sandbox does not implement them.

## Why sandboxes

Two reasons.

First, isolation: in multi-tenant deployments you may not want every agent
to read or write the host filesystem unrestricted. A virtual sandbox lets
you mount only the directories an agent should see and bound everything
else.

Second, portability: the same agent definition runs in development against
the real project (Local) and in production against an in-memory snapshot
(Virtual) without any code changes. Tests can build an isolated sandbox per
case and tear it down without touching disk.
