defmodule Condukt.SessionTest do
  use ExUnit.Case, async: true

  alias Condukt.Message
  alias Condukt.SessionStore.Snapshot
  alias Condukt.Test.LLMProvider
  alias ReqLLM.ToolCall

  defmodule ConfigAgent do
    use Condukt

    @impl true
    def system_prompt, do: "module prompt"

    @impl true
    def init(_opts) do
      {:ok, :ok}
    end
  end

  defmodule RecordingStore do
    @behaviour Condukt.SessionStore

    @impl true
    def load(opts) do
      case Keyword.get(opts, :snapshot) do
        nil -> :not_found
        snapshot -> {:ok, snapshot}
      end
    end

    @impl true
    def save(snapshot, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:saved_snapshot, snapshot})
      :ok
    end

    @impl true
    def clear(opts) do
      send(Keyword.fetch!(opts, :test_pid), :cleared_snapshot)
      :ok
    end
  end

  describe "session id" do
    test "generates a UUIDv7 by default" do
      {:ok, pid} = ConfigAgent.start_link(load_project_instructions: false)
      id = Condukt.Session.id(pid)

      assert is_binary(id)
      # 8-4-4-4-12 lowercase hex with version 7 in the third group.
      assert id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      GenServer.stop(pid)
    end

    test "honors an :id option passed by the caller" do
      explicit = "11111111-2222-7333-8444-555555555555"
      {:ok, pid} = ConfigAgent.start_link(id: explicit, load_project_instructions: false)

      assert Condukt.Session.id(pid) == explicit

      GenServer.stop(pid)
    end

    test "tags agent telemetry with the session id" do
      handler_id = "agent-session-id-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:condukt, :agent, :start], [:condukt, :agent, :stop]],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:agent_telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {model, _} = LLMProvider.model([LLMProvider.text_response("hi")])

      {:ok, pid} = ConfigAgent.start_link(model: model, load_project_instructions: false)
      id = Condukt.Session.id(pid)

      assert {:ok, "hi"} = Condukt.run(pid, "ping")

      assert_receive {:agent_telemetry, [:condukt, :agent, :start], %{session_id: ^id, agent: ConfigAgent}}
      assert_receive {:agent_telemetry, [:condukt, :agent, :stop], %{session_id: ^id, agent: ConfigAgent}}

      GenServer.stop(pid)
    end

    test "tags tool_call telemetry with the session id" do
      handler_id = "tool-call-session-id-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:condukt, :tool_call, :start], [:condukt, :tool_call, :stop]],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:tool_telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      tool =
        Condukt.tool(
          name: "noop",
          description: "noop",
          parameters: %{type: "object", properties: %{}},
          call: fn _args, _context -> {:ok, "ok"} end
        )

      tool_call = ToolCall.new("call_x", "noop", JSON.encode!(%{}))

      {model, _} =
        LLMProvider.model([
          LLMProvider.response(
            %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tool_call]},
            :tool_calls
          ),
          LLMProvider.text_response("done")
        ])

      {:ok, pid} = ConfigAgent.start_link(model: model, tools: [tool], load_project_instructions: false)
      id = Condukt.Session.id(pid)

      assert {:ok, "done"} = Condukt.run(pid, "go")

      assert_receive {:tool_telemetry, [:condukt, :tool_call, :start],
                      %{session_id: ^id, tool: "noop", agent: ConfigAgent}}

      assert_receive {:tool_telemetry, [:condukt, :tool_call, :stop],
                      %{session_id: ^id, tool: "noop", agent: ConfigAgent}}

      GenServer.stop(pid)
    end

    test "tool_call telemetry includes args, tool_call_id, status and result on success" do
      handler_id = "tool-call-payload-ok-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:condukt, :tool_call, :start], [:condukt, :tool_call, :stop]],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:tool_telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      tool =
        Condukt.tool(
          name: "echo",
          description: "echoes a message",
          parameters: %{type: "object", properties: %{message: %{type: "string"}}, required: ["message"]},
          call: fn %{"message" => message}, _context -> {:ok, "echo: " <> message} end
        )

      tool_call = ToolCall.new("call_ok", "echo", JSON.encode!(%{"message" => "hi"}))

      {model, _} =
        LLMProvider.model([
          LLMProvider.response(
            %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tool_call]},
            :tool_calls
          ),
          LLMProvider.text_response("done")
        ])

      {:ok, pid} = ConfigAgent.start_link(model: model, tools: [tool], load_project_instructions: false)

      assert {:ok, "done"} = Condukt.run(pid, "go")

      assert_receive {:tool_telemetry, [:condukt, :tool_call, :start],
                      %{tool: "echo", tool_call_id: "call_ok", args: %{"message" => "hi"}}}

      assert_receive {:tool_telemetry, [:condukt, :tool_call, :stop],
                      %{tool: "echo", tool_call_id: "call_ok", status: :ok, result: "echo: hi"}}

      GenServer.stop(pid)
    end

    test "tool_call telemetry surfaces :error status and the error tuple as :result" do
      handler_id = "tool-call-payload-error-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:condukt, :tool_call, :stop],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:tool_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      err_tool =
        Condukt.tool(
          name: "boom",
          description: "always errors",
          parameters: %{type: "object", properties: %{}},
          call: fn _args, _context -> {:error, "kaboom"} end
        )

      err_call = ToolCall.new("call_err", "boom", JSON.encode!(%{}))

      # max_turns: 1 stops the loop after the first tool batch so the broken
      # error tuple never has to be re-serialized for a second LLM turn.
      {model, _} =
        LLMProvider.model([
          LLMProvider.response(
            %ReqLLM.Message{role: :assistant, content: [], tool_calls: [err_call]},
            :tool_calls
          )
        ])

      {:ok, pid} = ConfigAgent.start_link(model: model, tools: [err_tool], load_project_instructions: false)

      Condukt.run(pid, "go", max_turns: 1)

      assert_receive {:tool_telemetry,
                      %{tool: "boom", tool_call_id: "call_err", status: :error, result: {:error, "kaboom"}}}

      GenServer.stop(pid)
    end

    test "emits :llm_turn events with the conversation context and assistant response" do
      handler_id = "llm-turn-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:condukt, :llm_turn, :start], [:condukt, :llm_turn, :stop]],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:llm_turn, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {model, _} = LLMProvider.model([LLMProvider.text_response("hello back")])

      {:ok, pid} = ConfigAgent.start_link(model: model, load_project_instructions: false)
      id = Condukt.Session.id(pid)

      assert {:ok, "hello back"} = Condukt.run(pid, "hi there")

      assert_receive {:llm_turn, [:condukt, :llm_turn, :start],
                      %{
                        agent: ConfigAgent,
                        session_id: ^id,
                        turn: 0,
                        streaming?: false,
                        messages: messages,
                        tool_count: tool_count
                      }}

      assert is_list(messages)
      assert tool_count == 0
      assert Enum.any?(messages, fn msg -> msg.role == :user and Message.text(msg) == "hi there" end)

      assert_receive {:llm_turn, [:condukt, :llm_turn, :stop],
                      %{
                        agent: ConfigAgent,
                        session_id: ^id,
                        turn: 0,
                        status: :ok,
                        assistant_message: %Message{role: :assistant} = assistant_message
                      }}

      assert Message.text(assistant_message) == "hello back"

      GenServer.stop(pid)
    end

    test "emits one :llm_turn pair per loop iteration with increasing :turn" do
      handler_id = "llm-turn-multi-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:condukt, :llm_turn, :start], [:condukt, :llm_turn, :stop]],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:llm_turn, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      tool =
        Condukt.tool(
          name: "noop",
          description: "noop",
          parameters: %{type: "object", properties: %{}},
          call: fn _args, _context -> {:ok, "ok"} end
        )

      tool_call = ToolCall.new("call_z", "noop", JSON.encode!(%{}))

      {model, _} =
        LLMProvider.model([
          LLMProvider.response(
            %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tool_call]},
            :tool_calls
          ),
          LLMProvider.text_response("done")
        ])

      {:ok, pid} = ConfigAgent.start_link(model: model, tools: [tool], load_project_instructions: false)

      assert {:ok, "done"} = Condukt.run(pid, "go")

      assert_receive {:llm_turn, [:condukt, :llm_turn, :start], %{turn: 0, tool_count: 1}}
      assert_receive {:llm_turn, [:condukt, :llm_turn, :stop], %{turn: 0, status: :ok}}
      assert_receive {:llm_turn, [:condukt, :llm_turn, :start], %{turn: 1, tool_count: 1}}
      assert_receive {:llm_turn, [:condukt, :llm_turn, :stop], %{turn: 1, status: :ok}}

      GenServer.stop(pid)
    end

    test "tool_call telemetry redacts session secrets from the result" do
      handler_id = "tool-call-redacted-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:condukt, :tool_call, :stop],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:tool_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      tool =
        Condukt.tool(
          name: "show_secret",
          description: "Returns a configured secret",
          parameters: %{type: "object", properties: %{}},
          call: fn _args, _context -> {:ok, "secret-token"} end
        )

      tool_call = ToolCall.new("call_redacted", "show_secret", JSON.encode!(%{}))

      {model, _} =
        LLMProvider.model([
          LLMProvider.response(
            %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tool_call]},
            :tool_calls
          ),
          LLMProvider.text_response("done")
        ])

      {:ok, pid} =
        ConfigAgent.start_link(
          model: model,
          tools: [tool],
          secrets: [GH_TOKEN: {:static, "secret-token"}],
          load_project_instructions: false
        )

      assert {:ok, "done"} = Condukt.run(pid, "go")

      assert_receive {:tool_telemetry, %{tool: "show_secret", status: :ok, result: result}}
      assert result == "[REDACTED:GH_TOKEN]"
      refute inspect(result) =~ "secret-token"

      GenServer.stop(pid)
    end

    test "secrets telemetry includes the session id" do
      handler_id = "secrets-session-id-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:condukt, :secrets, :resolve],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:secret_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pid} =
        ConfigAgent.start_link(
          secrets: [GH_TOKEN: {:static, "secret-token"}],
          load_project_instructions: false
        )

      id = Condukt.Session.id(pid)

      assert_receive {:secret_telemetry, %{session_id: ^id, agent: ConfigAgent}}

      GenServer.stop(pid)
    end

    test "tools receive the session id in their context" do
      test_pid = self()

      tool =
        Condukt.tool(
          name: "echo_session",
          description: "echoes the session id",
          parameters: %{type: "object", properties: %{}},
          call: fn _args, context ->
            send(test_pid, {:tool_context, context})
            {:ok, "ok"}
          end
        )

      tool_call = ToolCall.new("call_y", "echo_session", JSON.encode!(%{}))

      {model, _} =
        LLMProvider.model([
          LLMProvider.response(
            %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tool_call]},
            :tool_calls
          ),
          LLMProvider.text_response("done")
        ])

      {:ok, pid} = ConfigAgent.start_link(model: model, tools: [tool], load_project_instructions: false)
      id = Condukt.Session.id(pid)

      assert {:ok, "done"} = Condukt.run(pid, "go")

      assert_receive {:tool_context, %{session_id: ^id}}

      GenServer.stop(pid)
    end
  end

  test "transient sessions are not linked to the caller" do
    assert {:ok, {pid, links}} =
             Condukt.Session.with_transient(ConfigAgent, [load_project_instructions: false], fn pid ->
               {:ok, {pid, elem(Process.info(self(), :links), 1)}}
             end)

    refute pid in links
    refute Process.alive?(pid)
  end

  test "stores the configured :redactor on the session state" do
    {:ok, pid} =
      ConfigAgent.start_link(
        redactor: {Condukt.Redactors.Regex, extra_patterns: []},
        load_project_instructions: false
      )

    state = :sys.get_state(pid)
    assert state.redactor == {Condukt.Redactors.Regex, extra_patterns: []}

    GenServer.stop(pid)
  end

  test "redactor defaults to nil when no option is given" do
    {:ok, pid} = ConfigAgent.start_link(load_project_instructions: false)
    assert :sys.get_state(pid).redactor == nil
    GenServer.stop(pid)
  end

  test "stores resolved secrets on the session state" do
    {:ok, pid} =
      ConfigAgent.start_link(
        secrets: [GH_TOKEN: {:static, "secret-token"}],
        load_project_instructions: false
      )

    assert :sys.get_state(pid).secrets == %Condukt.Secrets{env: [{"GH_TOKEN", "secret-token"}]}

    GenServer.stop(pid)
  end

  test "emits telemetry when session secrets resolve" do
    handler_id = "secrets-resolve-test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:condukt, :secrets, :resolve],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:secret_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, pid} =
      ConfigAgent.start_link(
        secrets: [GH_TOKEN: {:static, "secret-token"}, DATABASE_URL: {:static, "postgres://secret"}],
        load_project_instructions: false
      )

    assert_receive {:secret_telemetry, [:condukt, :secrets, :resolve], %{count: 2}, metadata}
    assert metadata.agent == ConfigAgent
    assert Enum.sort(metadata.names) == ["DATABASE_URL", "GH_TOKEN"]
    refute inspect(metadata) =~ "secret-token"
    refute inspect(metadata) =~ "postgres://secret"

    GenServer.stop(pid)
  end

  test "returns a secrets init failure when configured secrets cannot resolve" do
    previous = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, previous)
    end)

    assert {:error, {:secrets_init_failed, :static_secret_requires_value}} =
             ConfigAgent.start_link(
               secrets: [API_TOKEN: {Condukt.Secrets.Providers.Static, []}],
               load_project_instructions: false
             )
  end

  test "redacts session secrets from tool results before the next model turn" do
    handler_id = "secrets-access-test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:condukt, :secrets, :access],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:secret_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    tool =
      Condukt.tool(
        name: "show_secret",
        description: "Returns a configured secret",
        parameters: %{type: "object", properties: %{}},
        call: fn _args, _context -> {:ok, "secret-token"} end
      )

    tool_call = ToolCall.new("call_1", "show_secret", JSON.encode!(%{}))

    {model, model_id} =
      LLMProvider.model([
        LLMProvider.response(
          %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tool_call]},
          :tool_calls
        ),
        LLMProvider.text_response("done")
      ])

    {:ok, pid} =
      ConfigAgent.start_link(
        model: model,
        tools: [tool],
        secrets: [GH_TOKEN: {:static, "secret-token"}],
        load_project_instructions: false
      )

    assert {:ok, "done"} = Condukt.run(pid, "call the tool")

    assert_receive {:secret_telemetry, [:condukt, :secrets, :access], %{count: 1}, metadata}
    assert metadata.agent == ConfigAgent
    assert metadata.tool == "show_secret"
    assert metadata.tool_call_id == "call_1"
    assert metadata.names == ["GH_TOKEN"]
    refute inspect(metadata) =~ "secret-token"

    assert_receive {LLMProvider, :request, ^model_id, _first_context, _first_opts}
    assert_receive {LLMProvider, :request, ^model_id, second_context, _second_opts}

    context_dump = inspect(second_context)
    assert context_dump =~ "[REDACTED:GH_TOKEN]"
    refute context_dump =~ "secret-token"

    assert Enum.any?(Condukt.history(pid), fn
             %Message{role: :tool_result, content: "[REDACTED:GH_TOKEN]"} -> true
             _ -> false
           end)

    GenServer.stop(pid)
  end

  test "uses config defaults when options are omitted" do
    {:ok, pid} =
      ConfigAgent.start_link(
        config: [
          api_key: "config-key",
          model: "openai:gpt-4o-mini",
          system_prompt: "config prompt",
          thinking_level: :low,
          cwd: "/tmp/agent"
        ],
        load_project_instructions: false
      )

    state = :sys.get_state(pid)

    assert state.api_key == "config-key"
    assert state.model == "openai:gpt-4o-mini"
    assert state.system_prompt == "config prompt"
    assert state.thinking_level == :low
    assert state.cwd == "/tmp/agent"
    assert state.user_state == :ok

    GenServer.stop(pid)
  end

  test "start_link options override config values" do
    {:ok, pid} =
      ConfigAgent.start_link(
        config: [
          api_key: "config-key",
          system_prompt: "config prompt"
        ],
        api_key: "option-key",
        system_prompt: "option prompt",
        load_project_instructions: false
      )

    state = :sys.get_state(pid)

    assert state.api_key == "option-key"
    assert state.system_prompt == "option prompt"
    assert state.user_state == :ok

    GenServer.stop(pid)
  end

  test "restores persisted session messages and settings when not explicitly configured" do
    snapshot = %Snapshot{
      messages: [Message.user("restored prompt"), Message.assistant("restored reply")],
      model: "openai:gpt-4o-mini",
      thinking_level: :low,
      system_prompt: "persisted prompt"
    }

    {:ok, pid} =
      ConfigAgent.start_link(
        session_store: {RecordingStore, snapshot: snapshot, test_pid: self()},
        load_project_instructions: false
      )

    state = :sys.get_state(pid)

    assert state.messages == snapshot.messages
    assert state.model == snapshot.model
    assert state.thinking_level == snapshot.thinking_level
    assert state.system_prompt == snapshot.system_prompt

    GenServer.stop(pid)
  end

  test "explicit options override restored session settings" do
    snapshot = %Snapshot{
      messages: [Message.user("restored prompt")],
      model: "openai:gpt-4o-mini",
      thinking_level: :low,
      system_prompt: "persisted prompt"
    }

    {:ok, pid} =
      ConfigAgent.start_link(
        model: "anthropic:claude-sonnet-4-20250514",
        thinking_level: :high,
        system_prompt: "explicit prompt",
        session_store: {RecordingStore, snapshot: snapshot, test_pid: self()},
        load_project_instructions: false
      )

    state = :sys.get_state(pid)

    assert state.messages == snapshot.messages
    assert state.model == "anthropic:claude-sonnet-4-20250514"
    assert state.thinking_level == :high
    assert state.system_prompt == "explicit prompt"

    GenServer.stop(pid)
  end

  test "clear removes persisted session state" do
    snapshot = %Snapshot{
      messages: [Message.user("restored prompt")],
      model: "openai:gpt-4o-mini",
      thinking_level: :low,
      system_prompt: "persisted prompt"
    }

    {:ok, pid} =
      ConfigAgent.start_link(
        session_store: {RecordingStore, snapshot: snapshot, test_pid: self()},
        load_project_instructions: false
      )

    assert :ok = Condukt.clear(pid)
    assert_receive :cleared_snapshot
    assert Condukt.history(pid) == []

    GenServer.stop(pid)
  end

  defmodule LastOneCompactor do
    @behaviour Condukt.Compactor

    @impl true
    def compact(messages, _opts) do
      {:ok, Enum.take(messages, -1)}
    end
  end

  test "compactor is applied after stream_complete and the trimmed history is persisted" do
    ref = make_ref()
    messages = [Message.user("a"), Message.assistant("b"), Message.user("c"), Message.assistant("d")]

    state = %Condukt.Session{
      agent_module: ConfigAgent,
      model: "openai:gpt-4o-mini",
      thinking_level: :medium,
      configured_system_prompt: "prompt",
      system_prompt: "prompt",
      cwd: "/tmp/agent",
      session_store: {RecordingStore, test_pid: self()},
      compactor: LastOneCompactor,
      project_context: %{agents_md: nil, skills: [], prompt: nil},
      user_state: :ok
    }

    handler_id = "compact-test-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:condukt, :compact, :stop],
      fn _event, measurements, metadata, _ ->
        send(self(), {:compact_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:noreply, updated_state} =
             Condukt.Session.handle_cast(
               {:stream_complete, ref, {:ok, messages, "d", %{}}},
               state
             )

    assert length(updated_state.messages) == 1
    assert hd(updated_state.messages).content == "d"

    assert_receive {:saved_snapshot, %Snapshot{messages: persisted}}
    assert length(persisted) == 1

    assert_receive {:compact_telemetry, %{before: 4, after: 1, duration: _}, %{agent: ConfigAgent}}
  end

  test "compact/1 is a no-op when no compactor is configured" do
    {:ok, pid} =
      ConfigAgent.start_link(load_project_instructions: false)

    assert :ok = Condukt.compact(pid)

    GenServer.stop(pid)
  end

  test "compact/1 trims history using the configured compactor" do
    {:ok, pid} =
      ConfigAgent.start_link(
        compactor: LastOneCompactor,
        load_project_instructions: false
      )

    :sys.replace_state(pid, fn s ->
      %{s | messages: [Message.user("a"), Message.user("b"), Message.user("c")]}
    end)

    assert :ok = Condukt.compact(pid)
    history = Condukt.history(pid)
    assert length(history) == 1
    assert hd(history).content == "c"

    GenServer.stop(pid)
  end

  test "stream completion updates history and persists the final snapshot" do
    ref = make_ref()
    messages = [Message.user("hello"), Message.assistant("world")]

    state = %Condukt.Session{
      agent_module: ConfigAgent,
      model: "openai:gpt-4o-mini",
      thinking_level: :medium,
      configured_system_prompt: "prompt",
      system_prompt: "prompt\n\n## Project Instructions\n\nUse mix test.",
      cwd: "/tmp/agent",
      session_store: {RecordingStore, test_pid: self()},
      project_context: %{agents_md: nil, skills: [], prompt: nil},
      user_state: :ok
    }

    assert {:noreply, updated_state} =
             Condukt.Session.handle_cast(
               {:stream_complete, ref, {:ok, messages, "world", %{}}},
               state
             )

    assert updated_state.messages == messages

    assert_receive {:saved_snapshot,
                    %Snapshot{
                      messages: ^messages,
                      model: "openai:gpt-4o-mini",
                      thinking_level: :medium,
                      system_prompt: "prompt"
                    }}
  end

  @tag :tmp_dir
  test "discovers project instructions and local skills from the project root", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "AGENTS.md"), "Always run project checks.")

    skill_dir = Path.join(cwd, ".agents/skills/release")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      description: Prepare a release safely.
      ---

      Verify the changelog and version before releasing.
      """
    )

    {:ok, pid} =
      ConfigAgent.start_link(
        cwd: cwd,
        system_prompt: "base prompt"
      )

    state = :sys.get_state(pid)

    assert state.configured_system_prompt == "base prompt"
    assert state.system_prompt =~ "base prompt"
    assert state.system_prompt =~ "Always run project checks."
    assert state.system_prompt =~ ".agents/skills/release/SKILL.md"

    assert state.project_context.skills == [
             %Condukt.Context.Skill{
               name: "release",
               path: ".agents/skills/release/SKILL.md",
               description: "Prepare a release safely."
             }
           ]

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "project instructions can be disabled", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "AGENTS.md"), "Do not leak into the prompt.")

    {:ok, pid} =
      ConfigAgent.start_link(
        cwd: cwd,
        system_prompt: "base prompt",
        load_project_instructions: false
      )

    state = :sys.get_state(pid)

    assert state.system_prompt == "base prompt"
    assert state.project_context == %{agents_md: nil, skills: [], prompt: nil}

    GenServer.stop(pid)
  end
end
