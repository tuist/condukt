defmodule Condukt.Sandbox.Kubernetes do
  @moduledoc """
  Sandbox that runs each session inside a dedicated Kubernetes Pod.

  One Pod per session. All filesystem reads and writes and all subprocess
  execution happen inside the Pod via the Kubernetes exec API. The agent
  cannot reach the host running the Condukt BEAM process.

  ## Idempotent init with a stable `:id`

  When you pass an `:id` opt, `init/1` is idempotent: it derives a
  deterministic Pod name from the id and either adopts an existing Pod or
  creates a fresh one. This is the recommended pattern for Oban-style
  workers where the job lifecycle and the Pod lifecycle are decoupled:

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

  If the job is retried after a crash, the same `session_id` flows through
  and the sandbox reattaches to the existing Pod. Repo clones and in-progress
  file edits persist (they live in an `emptyDir` volume mounted at the
  session cwd, which survives container restarts within the same Pod).

  When `:id` is omitted, a UUID is generated and the Pod is single-use:
  `shutdown/1` deletes it.

  ## Init options

  * `:id` — stable session id. If supplied, the pod is named deterministically
    and `init/1` is idempotent (adopt if exists, create otherwise). If
    omitted, a UUID is generated and `shutdown/1` deletes the pod.
  * `:namespace` — Kubernetes namespace (default `"default"`).
  * `:image` — container image (default `"debian:bookworm-slim"`).
  * `:cwd` — working directory inside the pod, also where the workspace
    volume is mounted (default `"/workspace"`).
  * `:env` — environment variables to set on the pod container, as a map or
    list of `{key, value}` pairs.
  * `:labels` — additional pod labels (caller-supplied; merged on top of
    Condukt's defaults).
  * `:annotations` — additional pod annotations.
  * `:resources` — Kubernetes resource requests/limits map, e.g.
    `%{requests: %{cpu: "500m", memory: "1Gi"}, limits: %{cpu: "2", memory: "4Gi"}}`.
  * `:service_account` — Kubernetes ServiceAccount the pod runs as.
  * `:active_deadline_seconds` — K8s-side hard ceiling for the pod's lifetime
    (default 8 hours). Insurance against abandoned pods.
  * `:heartbeat_interval` — milliseconds between pod heartbeat annotation
    updates (default `60_000`). Pass `false` to disable. Use
    `reap_stale/1` from a separate process to delete pods whose heartbeat is
    too old.
  * `:workspace_source` — git repository to clone into the workspace at init.
    Accepts a git URL string or a keyword/map with `:git` and optional `:ref`.
    The runtime image must include `git`.
  * `:workspace_source_timeout` — milliseconds to wait for the workspace
    clone or checkout command (default `300_000`).
  * `:ready_timeout` — milliseconds to wait for a created pod to reach
    Running phase (default `120_000`).
  * `:on_stale` — what to do when adopting a pod that is in an unexpected
    phase (Succeeded / Failed). `:error` (default) returns
    `{:error, {:stale_pod, phase}}`; `:recreate` deletes and recreates.
  * `:delete_on_shutdown` — whether `shutdown/1` deletes the pod. Defaults
    to `false` when `:id` is supplied (the pod outlives any single BEAM
    process), `true` when no id is given.
  * `:conn` — already-built `K8s.Conn`. Skips kubeconfig/in-cluster
    resolution.
  * `:kubeconfig` — path to a kubeconfig file (default `~/.kube/config`).
  * `:context` — kubeconfig context name (default: current-context).
  * `:in_cluster` — `true` to use the pod's mounted ServiceAccount token.
    Auto-detected when `KUBERNETES_SERVICE_HOST` is set, so usually not
    needed.

  ## RBAC

  The Kubernetes identity used by the Condukt process needs:

      apiGroups: [""]
      resources: ["pods"]
      verbs: ["get", "list", "create", "patch", "delete"]

      apiGroups: [""]
      resources: ["pods/exec"]
      verbs: ["create"]

  See `guides/sandbox.md` for a full sample `Role` + `RoleBinding`.

  ## Limitations

  * `mount/3` is not supported. Volumes cannot be added to a running pod.
  * Node failure loses the pod's `emptyDir` workspace. Mount a
    PersistentVolumeClaim into the pod manifest if you need cross-node
    durability — currently requires a custom `:image` setup, not exposed
    as an init option in v1.
  * `:workspace_source` shells out to `git` inside the pod. Use an image that
    includes `git` when enabling it.
  """

  @behaviour Condukt.Sandbox

  alias Condukt.Sandbox
  alias Condukt.Sandbox.Kubernetes.PodSpec
  alias Condukt.Sandbox.Kubernetes.State

  @default_image "debian:bookworm-slim"
  @default_cwd "/workspace"
  @default_namespace "default"
  @default_active_deadline 8 * 3600
  @default_ready_timeout 120_000
  @default_heartbeat_interval 60_000
  @default_reap_stale_after 15 * 60_000
  @default_workspace_source_timeout 300_000
  @ready_poll_interval 1_000
  @timeout_exit_code 124
  @timeout_grace_ms 5_000

  @managed_by_label "app.kubernetes.io/managed-by"
  @managed_by_value "condukt"
  @id_label "condukt.io/id"
  @created_annotation "condukt.io/created-at"
  @heartbeat_annotation "condukt.io/heartbeat-at"

  # ============================================================================
  # Sandbox callbacks
  # ============================================================================

  @impl Sandbox
  def init(opts) do
    with {:ok, conn} <- resolve_conn(opts),
         {:ok, config} <- build_config(opts),
         {:ok, state} <- ensure_pod(conn, config),
         {:ok, state} <- prepare_workspace(state, config) do
      start_heartbeat(state, config)
    end
  end

  @impl Sandbox
  def shutdown(%State{} = state) do
    stop_heartbeat(state)

    if state.delete_on_shutdown do
      delete_pod(state.conn, state.namespace, state.pod_name)
    end

    :ok
  end

  @impl Sandbox
  def read_file(state, path) do
    case run_exec(state, ["cat", "--", path]) do
      {:ok, %{output: output, exit_code: 0}} ->
        {:ok, output}

      {:ok, %{exit_code: _, output: output}} ->
        {:error, format_remote_error(output)}

      {:error, _} = err ->
        err
    end
  end

  @impl Sandbox
  def write_file(state, path, content) do
    script = """
    set -e
    mkdir -p -- "$(dirname -- #{shell_quote(path)})"
    cat > #{shell_quote(path)}
    """

    case run_exec_with_stdin(state, ["bash", "-c", script], content) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{output: output}} -> {:error, format_remote_error(output)}
      {:error, _} = err -> err
    end
  end

  @impl Sandbox
  def edit_file(state, path, old_text, new_text) do
    with {:ok, content} <- read_file(state, path) do
      apply_edit(state, path, content, old_text, new_text)
    end
  end

  @impl Sandbox
  def exec(state, command, opts) do
    cwd = Keyword.get(opts, :cwd) || state.base_cwd
    env = Keyword.get(opts, :env, [])
    timeout = Keyword.get(opts, :timeout, 120_000)

    script =
      command
      |> wrap_with_cwd(cwd)
      |> prepend_env_exports(env)
      |> wrap_with_timeout(timeout)

    case run_exec(state, ["bash", "-c", script], timeout: timeout + @timeout_grace_ms) do
      {:ok, %{exit_code: @timeout_exit_code}} -> {:error, :timeout}
      result -> result
    end
  end

  @impl Sandbox
  def glob(state, pattern, opts) do
    base = Keyword.get(opts, :cwd) || state.base_cwd
    limit = opts[:limit]

    script = """
    cd #{shell_quote(base)} 2>/dev/null || exit 0
    shopt -s globstar nullglob dotglob
    for p in #{pattern}; do
      [ -e "$p" ] && printf '%s\\n' "$p"
    done
    """

    case run_exec(state, ["bash", "-c", script]) do
      {:ok, %{output: output, exit_code: 0}} ->
        {:ok, output |> split_lines() |> apply_limit(limit)}

      {:ok, %{output: output}} ->
        {:error, format_remote_error(output)}

      {:error, _} = err ->
        err
    end
  end

  @impl Sandbox
  def grep(state, pattern, opts) do
    base = Keyword.get(opts, :path) || state.base_cwd
    case_sensitive? = Keyword.get(opts, :case_sensitive, true)
    file_glob = Keyword.get(opts, :glob, "**/*")
    limit = Keyword.get(opts, :limit, 1_000)

    case_flag = if case_sensitive?, do: "", else: "-i"

    script = """
    cd #{shell_quote(base)} 2>/dev/null || exit 0
    shopt -s globstar nullglob dotglob
    status=1
    for p in #{file_glob}; do
      [ -f "$p" ] || continue
      grep -Hn #{case_flag} -e #{shell_quote(pattern)} -- "$p" 2>/dev/null
      code=$?
      case "$code" in
        0) status=0 ;;
        1) ;;
        *) exit "$code" ;;
      esac
    done
    exit "$status"
    """

    case run_exec(state, ["bash", "-c", script]) do
      {:ok, %{exit_code: 0, output: output}} -> {:ok, output |> parse_grep_output() |> apply_limit(limit)}
      {:ok, %{exit_code: 1, output: ""}} -> {:ok, []}
      {:ok, %{output: output}} -> {:error, format_remote_error(output)}
      {:error, _} = err -> err
    end
  end

  # mount/3 intentionally not implemented; running pods cannot accept volumes.

  # ============================================================================
  # Public helpers
  # ============================================================================

  @doc """
  Explicitly delete the pod backing a session.

  Use this when a session is truly done and you do not want the pod to
  outlive the BEAM process (the default when `:id` is set).

      Condukt.Sandbox.Kubernetes.terminate(id, namespace: "agents")
  """
  def terminate(id, opts \\ []) when is_binary(id) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    pod_name = pod_name_for(id)

    with {:ok, conn} <- resolve_conn(opts) do
      delete_pod(conn, namespace, pod_name)
    end
  end

  @doc """
  Updates the heartbeat annotation on a Kubernetes sandbox pod.

  The sandbox starts a linked heartbeat worker by default. This helper is
  exposed for callers that disable the worker and want to drive heartbeats
  from their own supervision tree.
  """
  def heartbeat(%Sandbox{module: __MODULE__, state: %State{} = state}), do: heartbeat(state)

  def heartbeat(%State{} = state), do: patch_heartbeat(state)

  @doc """
  Deletes Condukt-managed pods whose heartbeat annotation is older than
  `:stale_after`.

  Options:

    * `:namespace` - namespace to scan, default `"default"`.
    * `:stale_after` - heartbeat age in milliseconds, default 15 minutes.
    * `:now` - `DateTime` used for tests, default `DateTime.utc_now()`.
    * K8s connection options accepted by `init/1`, such as `:conn`,
      `:kubeconfig`, `:context`, and `:in_cluster`.
  """
  def reap_stale(opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    stale_after = Keyword.get(opts, :stale_after, @default_reap_stale_after)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, conn} <- resolve_conn(opts),
         {:ok, pods} <- list_pods(conn, namespace) do
      stale = Enum.filter(pods, &stale_pod?(&1, now, stale_after))
      delete_stale_pods(conn, namespace, stale)
    end
  end

  # ============================================================================
  # Pod lifecycle
  # ============================================================================

  defp ensure_pod(conn, config) do
    case get_pod(conn, config.namespace, config.pod_name) do
      {:ok, pod} -> adopt_or_recreate(conn, config, pod)
      {:error, :not_found} -> create_and_wait(conn, config)
      {:error, _} = err -> err
    end
  end

  defp adopt_or_recreate(conn, config, pod) do
    case pod_phase(pod) do
      "Running" ->
        {:ok, state_from_config(conn, config)}

      "Pending" ->
        wait_until_ready(conn, config)

      phase when phase in ["Succeeded", "Failed"] ->
        handle_stale(conn, config, phase)

      _other ->
        adopt_other_phase(conn, config, pod)
    end
  end

  defp adopt_other_phase(conn, config, pod) do
    if terminating?(pod) do
      recreate_after_deletion(conn, config)
    else
      wait_until_ready(conn, config)
    end
  end

  defp recreate_after_deletion(conn, config) do
    case wait_for_deletion(conn, config) do
      :ok -> create_and_wait(conn, config)
      err -> err
    end
  end

  defp handle_stale(conn, %{on_stale: :recreate} = config, _phase) do
    case delete_pod(conn, config.namespace, config.pod_name) do
      :ok -> recreate_after_deletion(conn, config)
      err -> err
    end
  end

  defp handle_stale(_conn, _config, phase) do
    {:error, {:stale_pod, phase}}
  end

  defp create_and_wait(conn, config) do
    manifest = PodSpec.build(config)

    case K8s.Client.run(K8s.Client.put_conn(K8s.Client.create(manifest), conn)) do
      {:ok, _pod} -> wait_until_ready(conn, config)
      {:error, %{message: "already exists" <> _}} -> wait_until_ready(conn, config)
      {:error, reason} -> {:error, format_api_error(reason)}
    end
  end

  defp prepare_workspace(state, %{workspace_source: nil}), do: {:ok, state}

  defp prepare_workspace(state, config) do
    source = config.workspace_source
    ref_script = workspace_ref_script(source.ref)

    script = """
    set -e
    cd #{shell_quote(config.cwd)}
    if [ -d .git ]; then
      #{ref_script}
      exit 0
    fi
    if [ -n "$(find . -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      echo "workspace #{config.cwd} is not empty and is not a git repository" >&2
      exit 73
    fi
    git clone #{shell_quote(source.git)} .
    #{ref_script}
    """

    case run_exec(state, ["bash", "-c", script], timeout: config.workspace_source_timeout) do
      {:ok, %{exit_code: 0}} -> {:ok, state}
      {:ok, %{output: output}} -> {:error, {:workspace_source, format_remote_error(output)}}
      {:error, reason} -> {:error, {:workspace_source, reason}}
    end
  end

  defp workspace_ref_script(nil), do: ":"

  defp workspace_ref_script(ref) do
    "git fetch --all --tags --prune && git -c advice.detachedHead=false checkout #{shell_quote(ref)}"
  end

  defp wait_until_ready(conn, config) do
    deadline = System.monotonic_time(:millisecond) + config.ready_timeout
    do_wait_until_ready(conn, config, deadline)
  end

  defp do_wait_until_ready(conn, config, deadline) do
    case get_pod(conn, config.namespace, config.pod_name) do
      {:ok, pod} -> handle_ready_poll(conn, config, deadline, pod)
      {:error, _} = err -> err
    end
  end

  defp handle_ready_poll(conn, config, deadline, pod) do
    case pod_phase(pod) do
      "Running" ->
        if container_ready?(pod),
          do: {:ok, state_from_config(conn, config)},
          else: sleep_or_timeout(conn, config, deadline)

      "Pending" ->
        sleep_or_timeout(conn, config, deadline)

      phase ->
        {:error, {:unexpected_pod_phase, phase}}
    end
  end

  defp sleep_or_timeout(conn, config, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :ready_timeout}
    else
      Process.sleep(@ready_poll_interval)
      do_wait_until_ready(conn, config, deadline)
    end
  end

  defp wait_for_deletion(conn, config) do
    deadline = System.monotonic_time(:millisecond) + config.ready_timeout
    do_wait_for_deletion(conn, config, deadline)
  end

  defp do_wait_for_deletion(conn, config, deadline) do
    case get_pod(conn, config.namespace, config.pod_name) do
      {:error, :not_found} ->
        :ok

      {:ok, _pod} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :delete_timeout}
        else
          Process.sleep(@ready_poll_interval)
          do_wait_for_deletion(conn, config, deadline)
        end

      {:error, _} = err ->
        err
    end
  end

  # ============================================================================
  # K8s client glue
  # ============================================================================

  defp get_pod(conn, namespace, name) do
    op = K8s.Client.get("v1", "Pod", namespace: namespace, name: name)

    case K8s.Client.run(conn, op) do
      {:ok, pod} -> {:ok, pod}
      {:error, %{status: 404}} -> {:error, :not_found}
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> {:error, :not_found}
      {:error, reason} -> {:error, format_api_error(reason)}
    end
  end

  defp list_pods(conn, namespace) do
    op = K8s.Client.list("v1", "Pod", namespace: namespace)

    case K8s.Client.run(conn, op) do
      {:ok, %{"items" => pods}} -> {:ok, pods}
      {:error, reason} -> {:error, format_api_error(reason)}
    end
  end

  defp delete_pod(conn, namespace, name) do
    op = K8s.Client.delete("v1", "Pod", namespace: namespace, name: name)

    case K8s.Client.run(conn, op) do
      {:ok, _} -> :ok
      {:error, %{status: 404}} -> :ok
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> :ok
      {:error, reason} -> {:error, format_api_error(reason)}
    end
  end

  defp patch_heartbeat(%State{} = state) do
    patch = %{
      "metadata" => %{
        "annotations" => %{
          @heartbeat_annotation => timestamp()
        }
      }
    }

    op = K8s.Client.patch("v1", "Pod", [namespace: state.namespace, name: state.pod_name], patch)

    case K8s.Client.run(state.conn, op) do
      {:ok, _pod} -> :ok
      {:error, reason} -> {:error, format_api_error(reason)}
    end
  end

  defp delete_stale_pods(conn, namespace, pods) do
    Enum.reduce_while(pods, {:ok, []}, fn pod, {:ok, deleted} ->
      name = pod_name(pod)

      case delete_pod(conn, namespace, name) do
        :ok -> {:cont, {:ok, [name | deleted]}}
        {:error, reason} -> {:halt, {:error, {:reap_failed, name, reason}}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      {:error, _} = err -> err
    end
  end

  defp run_exec(state, command_list, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    state
    |> exec_op(command_list)
    |> K8s.Client.put_conn(state.conn)
    |> K8s.Client.run(recv_timeout: timeout)
    |> normalize_exec_result()
  end

  defp run_exec_with_stdin(state, command_list, input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    parent = self()
    ref = make_ref()
    collector = spawn_link(fn -> exec_stream_collector(parent, ref, %{}) end)

    result =
      case K8s.Client.stream_to(state.conn, exec_op(state, command_list), [recv_timeout: timeout], collector) do
        {:ok, send_to_websocket} ->
          send_stdin(send_to_websocket, input)
          send_to_websocket.(:close)
          collect_exec_stream(ref, timeout)

        {:error, reason} ->
          {:error, format_api_error(reason)}
      end

    Process.unlink(collector)
    Process.exit(collector, :shutdown)
    result
  end

  defp exec_op(state, command_list) do
    K8s.Client.connect(
      "v1",
      "pods/exec",
      [namespace: state.namespace, name: state.pod_name],
      command: command_list,
      container: state.container,
      tty: false
    )
  end

  defp send_stdin(send_to_websocket, input) do
    input
    |> chunk_binary(32 * 1024)
    |> Enum.each(fn chunk -> send_to_websocket.({:stdin, chunk}) end)
  end

  defp chunk_binary("", _size), do: []

  defp chunk_binary(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_binary(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunk_binary(rest, size)]
  end

  defp exec_stream_collector(parent, ref, acc) do
    receive do
      {:open, true} ->
        exec_stream_collector(parent, ref, acc)

      {:stdout, data} ->
        exec_stream_collector(parent, ref, append_stream(acc, :stdout, data))

      {:stderr, data} ->
        exec_stream_collector(parent, ref, append_stream(acc, :stderr, data))

      {:error, data} ->
        exec_stream_collector(parent, ref, append_stream(acc, :error, data))

      {:close, _reason} ->
        send(parent, {ref, normalize_exec_result({:ok, acc})})

      :done ->
        send(parent, {ref, normalize_exec_result({:ok, acc})})
    end
  end

  defp append_stream(acc, key, data), do: Map.update(acc, key, data, &(&1 <> data))

  defp collect_exec_stream(ref, timeout) do
    receive do
      {^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  defp normalize_exec_result({:ok, response}) do
    stdout = Map.get(response, :stdout, "") || ""
    stderr = Map.get(response, :stderr, "") || ""
    error = Map.get(response, :error, "") || ""

    {:ok,
     %{
       output: stdout <> stderr,
       exit_code: derive_exit_code(error)
     }}
  end

  defp normalize_exec_result({:error, reason}), do: {:error, format_api_error(reason)}

  # K8s exec returns an error channel with a JSON-like status when the
  # remote command exits non-zero. Pull the exit code out of it if present.
  defp derive_exit_code(""), do: 0
  defp derive_exit_code(nil), do: 0

  defp derive_exit_code(error) when is_binary(error) do
    case Regex.run(~r/exit (?:status|code):?\s*(\d+)/i, error) do
      [_, code] -> String.to_integer(code)
      _ -> 1
    end
  end

  defp derive_exit_code(_), do: 1

  # ============================================================================
  # Config / state assembly
  # ============================================================================

  defp build_config(opts) do
    {id, generated?} =
      case Keyword.get(opts, :id) do
        nil -> {Uniq.UUID.uuid7(), true}
        binary when is_binary(binary) -> {binary, false}
      end

    pod_name = pod_name_for(id)
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    cwd = Keyword.get(opts, :cwd, @default_cwd)
    now = timestamp()

    delete_on_shutdown =
      Keyword.get_lazy(opts, :delete_on_shutdown, fn -> generated? end)

    with {:ok, workspace_source} <- normalize_workspace_source(Keyword.get(opts, :workspace_source)) do
      {:ok,
       %{
         id: id,
         generated_id?: generated?,
         pod_name: pod_name,
         namespace: namespace,
         image: Keyword.get(opts, :image, @default_image),
         cwd: cwd,
         env: normalize_env(Keyword.get(opts, :env, %{})),
         labels: build_labels(id, Keyword.get(opts, :labels, %{})),
         annotations: build_annotations(Keyword.get(opts, :annotations, %{}), now),
         resources: stringify_resources(Keyword.get(opts, :resources, %{})),
         service_account: Keyword.get(opts, :service_account),
         active_deadline_seconds: Keyword.get(opts, :active_deadline_seconds, @default_active_deadline),
         heartbeat_interval: Keyword.get(opts, :heartbeat_interval, @default_heartbeat_interval),
         workspace_source: workspace_source,
         workspace_source_timeout: Keyword.get(opts, :workspace_source_timeout, @default_workspace_source_timeout),
         ready_timeout: Keyword.get(opts, :ready_timeout, @default_ready_timeout),
         on_stale: Keyword.get(opts, :on_stale, :error),
         delete_on_shutdown: delete_on_shutdown
       }}
    end
  end

  defp state_from_config(conn, config) do
    %State{
      conn: conn,
      namespace: config.namespace,
      pod_name: config.pod_name,
      container: PodSpec.container_name(),
      base_cwd: config.cwd,
      id: config.id,
      delete_on_shutdown: config.delete_on_shutdown
    }
  end

  defp start_heartbeat(state, %{heartbeat_interval: false}), do: {:ok, state}
  defp start_heartbeat(state, %{heartbeat_interval: nil}), do: {:ok, state}

  defp start_heartbeat(state, %{heartbeat_interval: interval}) when is_integer(interval) and interval > 0 do
    pid = spawn_link(fn -> heartbeat_loop(state, interval) end)
    {:ok, %{state | heartbeat_pid: pid}}
  end

  defp start_heartbeat(_state, %{heartbeat_interval: interval}) do
    {:error, {:invalid_heartbeat_interval, interval}}
  end

  defp stop_heartbeat(%State{heartbeat_pid: nil}), do: :ok

  defp stop_heartbeat(%State{heartbeat_pid: pid}) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  defp heartbeat_loop(state, interval) do
    _ = patch_heartbeat(state)
    Process.sleep(interval)
    heartbeat_loop(state, interval)
  end

  defp build_labels(id, extra) do
    base = %{
      @managed_by_label => @managed_by_value,
      @id_label => sanitize_label_value(id)
    }

    Map.merge(base, stringify_map(extra))
  end

  defp build_annotations(extra, now) do
    extra
    |> stringify_map()
    |> Map.merge(%{
      @created_annotation => now,
      @heartbeat_annotation => now
    })
  end

  defp sanitize_label_value(id) do
    id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.\-]/, "-")
    |> String.slice(0, 63)
    |> String.trim("-")
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify_resources(map) when is_map(map) and map_size(map) == 0, do: %{}

  defp stringify_resources(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) -> {to_string(k), stringify_map(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp normalize_env(env) when is_map(env), do: stringify_map(env)

  defp normalize_env(env) when is_list(env) do
    Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_env(_), do: %{}

  defp normalize_workspace_source(nil), do: {:ok, nil}

  defp normalize_workspace_source(git) when is_binary(git), do: {:ok, %{git: git, ref: nil}}

  defp normalize_workspace_source(source) when is_list(source) do
    source
    |> Map.new(fn {key, value} -> {key, value} end)
    |> normalize_workspace_source()
  end

  defp normalize_workspace_source(source) when is_map(source) do
    git = Map.get(source, :git) || Map.get(source, "git")
    ref = Map.get(source, :ref) || Map.get(source, "ref")

    cond do
      not is_binary(git) ->
        {:error, ":workspace_source requires a git URL string or a :git entry"}

      not is_nil(ref) and not is_binary(ref) ->
        {:error, ":workspace_source :ref must be a string when provided"}

      true ->
        {:ok, %{git: git, ref: ref}}
    end
  end

  defp normalize_workspace_source(_other) do
    {:error, ":workspace_source must be a git URL string or keyword/map options"}
  end

  # ============================================================================
  # Connection resolution
  # ============================================================================

  defp resolve_conn(opts) do
    cond do
      conn = Keyword.get(opts, :conn) -> {:ok, conn}
      Keyword.get(opts, :in_cluster, false) -> from_service_account()
      in_cluster?() -> from_service_account()
      true -> from_kubeconfig(opts)
    end
  end

  defp in_cluster?, do: System.get_env("KUBERNETES_SERVICE_HOST") != nil

  defp from_service_account do
    case K8s.Conn.from_service_account() do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:k8s_conn, reason}}
    end
  end

  defp from_kubeconfig(opts) do
    path = Keyword.get(opts, :kubeconfig) || default_kubeconfig()
    conn_opts = if ctx = Keyword.get(opts, :context), do: [context: ctx], else: []

    case K8s.Conn.from_file(path, conn_opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:k8s_conn, reason}}
    end
  end

  defp default_kubeconfig do
    case System.get_env("KUBECONFIG") do
      nil -> Path.expand("~/.kube/config")
      val -> val |> String.split(":") |> List.first()
    end
  end

  # ============================================================================
  # Pod-name derivation
  # ============================================================================

  @doc false
  def pod_name_for(id) when is_binary(id) do
    sanitized =
      id
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)
      |> String.trim("-")

    hash =
      :crypto.hash(:sha256, id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 6)

    prefix = if sanitized == "", do: "s", else: sanitized
    "condukt-#{prefix}-#{hash}"
  end

  # ============================================================================
  # Misc helpers
  # ============================================================================

  defp pod_phase(pod), do: get_in(pod, ["status", "phase"]) || ""

  defp pod_name(pod), do: get_in(pod, ["metadata", "name"])

  defp stale_pod?(pod, now, stale_after) do
    managed_by_condukt?(pod) and stale_heartbeat?(pod, now, stale_after)
  end

  defp managed_by_condukt?(pod) do
    get_in(pod, ["metadata", "labels", @managed_by_label]) == @managed_by_value
  end

  defp stale_heartbeat?(pod, now, stale_after) do
    pod
    |> heartbeat_timestamp()
    |> stale_timestamp?(now, stale_after)
  end

  defp heartbeat_timestamp(pod) do
    get_in(pod, ["metadata", "annotations", @heartbeat_annotation]) ||
      get_in(pod, ["metadata", "annotations", @created_annotation])
  end

  defp stale_timestamp?(nil, _now, _stale_after), do: false

  defp stale_timestamp?(value, now, stale_after) do
    case DateTime.from_iso8601(value) do
      {:ok, heartbeat_at, _offset} ->
        DateTime.diff(now, heartbeat_at, :millisecond) >= stale_after

      {:error, _reason} ->
        false
    end
  end

  defp container_ready?(pod) do
    pod
    |> get_in(["status", "containerStatuses"])
    |> List.wrap()
    |> Enum.any?(&(&1["ready"] == true))
  end

  defp terminating?(pod), do: not is_nil(get_in(pod, ["metadata", "deletionTimestamp"]))

  defp apply_edit(state, path, content, old_text, new_text) do
    case count_occurrences(content, old_text) do
      0 ->
        {:ok, %{occurrences: 0, content: content}}

      n when n > 1 ->
        {:ok, %{occurrences: n, content: content}}

      1 ->
        {:ok, new_content} = replace_first(content, old_text, new_text)

        case write_file(state, path, new_content) do
          :ok -> {:ok, %{occurrences: 1, content: new_content}}
          err -> err
        end
    end
  end

  defp count_occurrences(content, old_text) do
    content
    |> String.split(old_text)
    |> length()
    |> Kernel.-(1)
  end

  defp replace_first(content, old_text, new_text) do
    case :binary.match(content, old_text) do
      :nomatch ->
        {:ok, content}

      {index, len} ->
        new_content =
          binary_part(content, 0, index) <>
            new_text <>
            binary_part(content, index + len, byte_size(content) - index - len)

        {:ok, new_content}
    end
  end

  defp wrap_with_cwd(command, nil), do: command
  defp wrap_with_cwd(command, cwd), do: "cd #{shell_quote(cwd)} && #{command}"

  defp wrap_with_timeout(script, timeout) when is_integer(timeout) and timeout > 0 do
    seconds = timeout |> Kernel./(1_000) |> :erlang.float_to_binary(decimals: 3)

    "timeout --kill-after=5s #{seconds}s bash -c #{shell_quote(script)}"
  end

  defp wrap_with_timeout(script, _timeout), do: script

  defp prepend_env_exports(script, env) do
    normalized = normalize_env(env)

    case Enum.filter(normalized, &valid_env_key?/1) do
      [] ->
        script

      list ->
        exports =
          Enum.map_join(list, "\n", fn {k, v} -> "export #{k}=#{shell_quote(v)}" end)

        exports <> "\n" <> script
    end
  end

  defp valid_env_key?({key, _value}), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key)

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  defp split_lines(""), do: []
  defp split_lines(s), do: String.split(s, "\n", trim: true)

  defp apply_limit(list, nil), do: list
  defp apply_limit(list, n) when is_integer(n) and n > 0, do: Enum.take(list, n)
  defp apply_limit(list, _), do: list

  defp parse_grep_output(""), do: []

  defp parse_grep_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_grep_line/1)
  end

  defp parse_grep_line(line) do
    with [path, line_number, content] <- String.split(line, ":", parts: 3),
         {n, ""} <- Integer.parse(line_number) do
      [%{path: path, line_number: n, line: content}]
    else
      _ -> []
    end
  end

  defp format_remote_error(""), do: :remote_error
  defp format_remote_error(output) when is_binary(output), do: {:remote_error, output}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp format_api_error(%{message: message}), do: message
  defp format_api_error(reason) when is_binary(reason), do: reason
  defp format_api_error(reason), do: inspect(reason)
end
