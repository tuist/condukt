defmodule Condukt.Workflows.ExecutorTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox
  alias Condukt.Workflows.{Document, Executor}

  defmodule RecordingSandbox do
    @behaviour Sandbox

    @impl Sandbox
    def init(opts), do: {:ok, opts}

    @impl Sandbox
    def shutdown(_state), do: :ok

    @impl Sandbox
    def read_file(_state, _path), do: {:error, :not_supported}

    @impl Sandbox
    def write_file(_state, _path, _content), do: {:error, :not_supported}

    @impl Sandbox
    def edit_file(_state, _path, _old_text, _new_text), do: {:error, :not_supported}

    @impl Sandbox
    def exec(state, command, opts) do
      send(Keyword.fetch!(state, :reply_to), {:sandbox_exec, command, opts})
      {:ok, %{output: "from sandbox\n", exit_code: 0}}
    end
  end

  defp doc(map) do
    {:ok, doc} = Document.from_map(map)
    doc
  end

  defp echo_argv(text), do: ["echo", text]

  describe "cmd step" do
    test "runs an echo command and records its output" do
      doc =
        doc(%{
          "steps" => %{
            "greet" => %{"kind" => "cmd", "argv" => echo_argv("hello")}
          },
          "output" => "${steps.greet.stdout}"
        })

      assert {:ok, %{output: "hello\n", steps: %{"greet" => %{"ok" => true}}}} =
               Executor.run(doc)
    end

    test "interpolates inputs into argv" do
      doc =
        doc(%{
          "inputs" => %{"name" => %{"type" => "string"}},
          "steps" => %{
            "greet" => %{"kind" => "cmd", "argv" => ["echo", "hi ${inputs.name}"]}
          },
          "output" => "${steps.greet.stdout}"
        })

      assert {:ok, %{output: "hi world\n"}} = Executor.run(doc, %{"name" => "world"})
    end

    test "uses a configured sandbox for command steps" do
      {:ok, sandbox} = Sandbox.new(RecordingSandbox, reply_to: self())

      doc =
        doc(%{
          "steps" => %{
            "greet" => %{"kind" => "cmd", "argv" => ["echo", "hello world"]}
          },
          "output" => "${steps.greet.stdout}"
        })

      assert {:ok, %{output: "from sandbox\n"}} = Executor.run(doc, %{}, sandbox: sandbox, cwd: "/work")
      assert_receive {:sandbox_exec, "echo 'hello world'", opts}
      assert opts[:cwd] == "/work"
      assert opts[:env] == []
    end

    @tag :tmp_dir
    test "uses the workflow runtime sandbox for built-in tools", %{tmp_dir: dir} do
      doc =
        doc(%{
          "runtime" => %{"sandbox" => "local", "cwd" => dir},
          "steps" => %{
            "pwd" => %{
              "kind" => "tool",
              "id" => "Bash",
              "args" => %{"command" => "pwd"}
            }
          },
          "output" => "${steps.pwd.output}"
        })

      assert {:ok, %{output: output}} = Executor.run(doc)
      assert String.trim(output) == dir
    end
  end

  describe "dependencies" do
    test "infers dependencies from ${steps.X.*} references" do
      doc =
        doc(%{
          "steps" => %{
            "first" => %{"kind" => "cmd", "argv" => echo_argv("one")},
            "second" => %{
              "kind" => "cmd",
              "argv" => ["echo", "${steps.first.stdout}"]
            }
          },
          "output" => "${steps.second.stdout}"
        })

      assert {:ok, %{output: "one\n\n"}} = Executor.run(doc)
    end

    test "rejects an unknown dependency" do
      doc =
        doc(%{
          "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["echo", "${steps.ghost.stdout}"]}}
        })

      assert {:error, {:unknown_dependency, "a", "ghost"}} = Executor.run(doc)
    end

    test "rejects a cycle" do
      doc =
        doc(%{
          "steps" => %{
            "a" => %{"kind" => "cmd", "argv" => ["echo", "${steps.b.stdout}"]},
            "b" => %{"kind" => "cmd", "argv" => ["echo", "${steps.a.stdout}"]}
          }
        })

      assert {:error, {:cycle, ["a", "b"]}} = Executor.run(doc)
    end
  end

  describe "when:" do
    test "runs the step when the condition is true" do
      doc =
        doc(%{
          "inputs" => %{"go" => %{"type" => "boolean"}},
          "steps" => %{
            "ping" => %{
              "kind" => "cmd",
              "argv" => echo_argv("pong"),
              "when" => "${inputs.go}"
            }
          },
          "output" => "${steps.ping.stdout}"
        })

      assert {:ok, %{output: "pong\n", skipped: []}} = Executor.run(doc, %{"go" => true})
    end

    test "skips the step when the condition is false" do
      doc =
        doc(%{
          "inputs" => %{"go" => %{"type" => "boolean"}},
          "steps" => %{
            "ping" => %{
              "kind" => "cmd",
              "argv" => echo_argv("pong"),
              "when" => "${inputs.go}"
            }
          }
        })

      assert {:ok, %{steps: %{"ping" => nil}, skipped: ["ping"]}} =
               Executor.run(doc, %{"go" => false})
    end

    test "cascade-skips downstream steps that depend on a skipped one" do
      doc =
        doc(%{
          "inputs" => %{"go" => %{"type" => "boolean"}},
          "steps" => %{
            "a" => %{
              "kind" => "cmd",
              "argv" => echo_argv("a"),
              "when" => "${inputs.go}"
            },
            "b" => %{
              "kind" => "cmd",
              "argv" => ["echo", "from a: ${steps.a.stdout}"]
            }
          }
        })

      assert {:ok, %{skipped: skipped}} = Executor.run(doc, %{"go" => false})
      assert Enum.sort(skipped) == ["a", "b"]
    end

    test "errors when the when expression does not produce a boolean" do
      doc =
        doc(%{
          "steps" => %{
            "x" => %{"kind" => "cmd", "argv" => echo_argv("x"), "when" => "hello"}
          }
        })

      assert {:error, {:when_failed, "x", {:when_not_boolean, "hello"}}} = Executor.run(doc)
    end
  end

  describe "map step" do
    test "fans out a cmd step over a list of items" do
      doc =
        doc(%{
          "inputs" => %{"items" => %{"type" => "array"}},
          "steps" => %{
            "fan" => %{
              "kind" => "map",
              "over" => "${inputs.items}",
              "as" => "item",
              "do" => %{
                "kind" => "cmd",
                "argv" => ["echo", "got ${item}"]
              }
            }
          },
          "output" => "${steps.fan}"
        })

      assert {:ok, %{output: results}} = Executor.run(doc, %{"items" => ["a", "b"]})
      assert [%{"stdout" => "got a\n"}, %{"stdout" => "got b\n"}] = results
    end

    test "errors when `over` is not a list" do
      doc =
        doc(%{
          "inputs" => %{"x" => %{"type" => "integer"}},
          "steps" => %{
            "fan" => %{
              "kind" => "map",
              "over" => "${inputs.x}",
              "as" => "item",
              "do" => %{"kind" => "cmd", "argv" => echo_argv("x")}
            }
          }
        })

      assert {:error, {:over_must_be_list, "fan", 1}} = Executor.run(doc, %{"x" => 1})
    end
  end

  describe "http step" do
    test "issues a request and exposes status, headers, and body" do
      adapter = fn req ->
        assert req.method == :get
        assert URI.parse(req.url).host == "example.test"

        {req,
         %Req.Response{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: %{"hello" => "world"}
         }}
      end

      doc =
        doc(%{
          "steps" => %{
            "fetch" => %{
              "kind" => "http",
              "method" => "GET",
              "url" => "https://example.test/items"
            }
          },
          "output" => "${steps.fetch.body.hello}"
        })

      assert {:ok, %{output: "world"}} =
               Executor.run(doc, %{}, req_options: [adapter: adapter])
    end

    test "fails the run when expect_status does not match" do
      adapter = fn req -> {req, %Req.Response{status: 500, headers: [], body: ""}} end

      doc =
        doc(%{
          "steps" => %{
            "fetch" => %{
              "kind" => "http",
              "method" => "GET",
              "url" => "https://example.test/",
              "expect_status" => 200
            }
          }
        })

      assert {:error, {:http_unexpected_status, "fetch", _}} =
               Executor.run(doc, %{}, req_options: [adapter: adapter])
    end
  end

  describe "output" do
    test "returns nil when no output is declared" do
      doc =
        doc(%{
          "steps" => %{"a" => %{"kind" => "cmd", "argv" => echo_argv("hi")}}
        })

      assert {:ok, %{output: nil}} = Executor.run(doc)
    end

    test "interpolates a structured output value" do
      doc =
        doc(%{
          "steps" => %{
            "a" => %{"kind" => "cmd", "argv" => echo_argv("alpha")},
            "b" => %{"kind" => "cmd", "argv" => echo_argv("beta")}
          },
          "output" => %{"a" => "${steps.a.stdout}", "b" => "${steps.b.stdout}"}
        })

      assert {:ok, %{output: %{"a" => "alpha\n", "b" => "beta\n"}}} = Executor.run(doc)
    end
  end
end
