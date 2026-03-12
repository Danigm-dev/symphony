defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Issue, as: NeutralIssue
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "workflow store persists azure repo settings into WORKFLOW.md and reloads config" do
    ensure_workflow_store_running()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_repository: nil,
      tracker_target_branch: nil,
      tracker_required_reviewers: nil,
      prompt: "Azure workflow prompt"
    )

    assert {:ok, workflow} =
             WorkflowStore.persist_azure_repo_settings(%{
               "repository" => "SymphonyRepo",
               "target_branch" => "main",
               "required_reviewers" => "alice@example.com\nbob@example.com"
             })

    assert get_in(workflow.config, ["tracker", "repository"]) == "SymphonyRepo"
    assert get_in(workflow.config, ["tracker", "target_branch"]) == "main"
    assert get_in(workflow.config, ["tracker", "required_reviewers"]) == ["alice@example.com", "bob@example.com"]
    assert Config.azure_devops_repository() == "SymphonyRepo"
    assert Config.azure_devops_target_branch() == "main"
    assert Config.azure_devops_required_reviewers() == ["alice@example.com", "bob@example.com"]
    assert {:ok, %{prompt: "Azure workflow prompt"}} = Workflow.current()

    persisted_workflow = File.read!(Workflow.workflow_file_path())
    assert persisted_workflow =~ ~s(repository: "SymphonyRepo")
    assert persisted_workflow =~ ~s(target_branch: "main")
    assert persisted_workflow =~ ~s(- "alice@example.com")
    assert persisted_workflow =~ ~s(- "bob@example.com")
  end

  test "workflow persistence validates azure repo settings inputs and works without the workflow store process" do
    ensure_workflow_store_running()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "linear-project"
    )

    assert {:error, :azure_repo_settings_require_azure_devops_tracker} =
             Workflow.persist_azure_repo_settings(%{"repository" => "repo", "target_branch" => "main"})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    assert {:error, :missing_azure_devops_repository} =
             Workflow.persist_azure_repo_settings(%{"repository" => " ", "target_branch" => "main"})

    assert {:error, :missing_azure_devops_repository} =
             Workflow.persist_azure_repo_settings(%{"repository" => 123, "target_branch" => "main"})

    assert {:error, :missing_azure_devops_target_branch} =
             Workflow.persist_azure_repo_settings(%{"repository" => "repo", "target_branch" => " "})

    assert {:error, :missing_azure_devops_target_branch} =
             Workflow.persist_azure_repo_settings(%{"repository" => "repo", "target_branch" => 123})

    assert :ok =
             Workflow.persist_azure_repo_settings(%{
               "repository" => "repo-with-reviewer-list",
               "target_branch" => "main",
               "required_reviewers" => [" alice@example.com ", nil, "bob@example.com", " "]
             })

    assert Config.azure_devops_repository() == "repo-with-reviewer-list"
    assert Config.azure_devops_required_reviewers() == ["alice@example.com", "bob@example.com"]

    assert :ok =
             Workflow.persist_azure_repo_settings(%{
               "repository" => "repo-with-empty-reviewer-list",
               "target_branch" => "main",
               "required_reviewers" => [nil, " "]
             })

    assert Config.azure_devops_repository() == "repo-with-empty-reviewer-list"
    assert Config.azure_devops_required_reviewers() == []

    stop_workflow_store!()

    assert :ok =
             Workflow.persist_azure_repo_settings(%{
               "repository" => "repo-without-store",
               "target_branch" => "main",
               "required_reviewers" => ""
             })

    assert Config.azure_devops_repository() == "repo-without-store"
    assert Config.azure_devops_target_branch() == "main"
    assert Config.azure_devops_required_reviewers() == []

    ensure_workflow_store_running()
  end

  test "workflow persistence rejects malformed cached workflows and returns write errors with the workflow store" do
    ensure_workflow_store_running()

    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_repository: "repo",
      tracker_target_branch: "main"
    )

    workflow_content = File.read!(workflow_path)

    assert :ok =
             WorkflowStore.replace_workflow(
               workflow_path,
               %{prompt: "Broken cache", prompt_template: "Broken cache"},
               workflow_content
             )

    assert {:error, :azure_repo_settings_require_azure_devops_tracker} =
             Workflow.persist_azure_repo_settings(%{"repository" => "repo", "target_branch" => "main"})

    write_workflow_file!(workflow_path,
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_repository: "repo",
      tracker_target_branch: "main"
    )

    assert {:ok, restored_workflow} = Workflow.load(workflow_path)
    restored_content = File.read!(workflow_path)
    assert :ok = WorkflowStore.replace_workflow(workflow_path, restored_workflow, restored_content)

    File.chmod!(workflow_path, 0o400)
    on_exit(fn -> File.chmod!(workflow_path, 0o644) end)

    assert {:error, :eacces} =
             Workflow.persist_azure_repo_settings(%{
               "repository" => "repo-live-store",
               "target_branch" => "release/2026"
             })
  end

  test "workflow persistence returns file write errors without the workflow store process" do
    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_repository: "repo",
      tracker_target_branch: "main"
    )

    stop_workflow_store!()
    File.chmod!(workflow_path, 0o400)
    on_exit(fn -> File.chmod!(workflow_path, 0o644) end)

    assert {:error, :eacces} =
             Workflow.persist_azure_repo_settings(%{
               "repository" => "repo-without-store",
               "target_branch" => "release/2026"
             })

    ensure_workflow_store_running()
  end

  test "workflow persistence serializes complex cached azure workflow values" do
    ensure_workflow_store_running()

    workflow_path = Workflow.workflow_file_path()
    workflow_content = File.read!(workflow_path)

    cached_workflow = %{
      config: %{
        "tracker" => %{
          "kind" => "azure_devops",
          "endpoint" => "https://dev.azure.com/openai",
          "api_key" => "azure-token",
          "project" => "Symphony",
          "repository" => "repo",
          "target_branch" => "main"
        },
        "workspace" => %{"tags" => []},
        "hooks" => %{
          "steps" => [%{"name" => "one", "enabled" => false}],
          "matrix" => [["a", "b"], ["c"]]
        },
        "observability" => %{"enabled" => false, "sample_rate" => 0.5},
        "server" => %{"mode" => :local}
      },
      prompt: "Azure workflow prompt",
      prompt_template: "Azure workflow prompt"
    }

    assert :ok = WorkflowStore.replace_workflow(workflow_path, cached_workflow, workflow_content)

    assert :ok =
             Workflow.persist_azure_repo_settings(%{
               "repository" => "complex-repo",
               "target_branch" => "release/2026"
             })

    assert {:ok, persisted_workflow} = Workflow.current()
    assert get_in(persisted_workflow.config, ["workspace", "tags"]) == []
    assert get_in(persisted_workflow.config, ["hooks", "steps"]) == [%{"enabled" => false, "name" => "one"}]
    assert get_in(persisted_workflow.config, ["hooks", "matrix"]) == [["a", "b"], ["c"]]
    assert get_in(persisted_workflow.config, ["observability", "enabled"]) == false
    assert get_in(persisted_workflow.config, ["observability", "sample_rate"]) == 0.5
    assert get_in(persisted_workflow.config, ["server", "mode"]) == "local"

    persisted_content = File.read!(workflow_path)
    assert persisted_content =~ "tags: []"
    assert persisted_content =~ "steps:"
    assert persisted_content =~ "enabled: false"
    assert persisted_content =~ "sample_rate: 0.5"
    assert persisted_content =~ ~s(mode: "local")
  end

  test "workflow infers azure repo names only from azure remotes" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    original_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", original_path) end)

    configure_git_origin!(workflow_dir, "git@ssh.dev.azure.com:v3/openai/Symphony/ssh-repo")
    assert Workflow.infer_azure_repo_from_origin() == "ssh-repo"

    configure_git_origin!(workflow_dir, "https://github.com/openai/symphony.git")
    assert Workflow.infer_azure_repo_from_origin() == nil

    configure_git_origin!(workflow_dir, "https://dev.azure.com/openai/Symphony/_git/.git")
    assert Workflow.infer_azure_repo_from_origin() == nil

    System.put_env("PATH", "")
    assert Workflow.infer_azure_repo_from_origin() == nil
  end

  test "workflow store replace_workflow updates cached state and returns file errors directly" do
    ensure_workflow_store_running()

    workflow = %{
      config: %{"tracker" => %{"kind" => "azure_devops", "repository" => "replaced-repo", "target_branch" => "main"}},
      prompt: "Replaced prompt",
      prompt_template: "Replaced prompt"
    }

    content = """
    ---
    tracker:
      kind: "azure_devops"
      repository: "replaced-repo"
      target_branch: "main"
    ---
    Replaced prompt
    """

    File.write!(Workflow.workflow_file_path(), content)
    assert :ok = WorkflowStore.replace_workflow(Workflow.workflow_file_path(), workflow, content)
    assert {:ok, ^workflow} = WorkflowStore.current()

    assert {:error, :enoent} =
             WorkflowStore.replace_workflow(
               Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md"),
               workflow,
               content
             )

    stop_workflow_store!()
    assert :ok = WorkflowStore.replace_workflow(Workflow.workflow_file_path(), workflow, content)
    ensure_workflow_store_running()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    neutral_issue = NeutralIssue.from(issue)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.tracker_kind() == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^neutral_issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^neutral_issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^neutral_issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "azure_devops")
    assert SymphonyElixir.Tracker.adapter() == SymphonyElixir.AzureDevOps.Adapter
  end

  test "tracker raises explicit errors for missing or unsupported tracker kinds" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: nil)
    assert_raise ArgumentError, "missing tracker kind", fn -> SymphonyElixir.Tracker.adapter() end

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    assert_raise ArgumentError, ~r/^unsupported tracker kind: "jira"$/, fn ->
      SymphonyElixir.Tracker.adapter()
    end
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom"
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{"path" => Path.join(Config.workspace_root(), "MT-HTTP")},
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview captures missing azure repo settings, prefills from origin, and persists manual overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_repository: nil,
      tracker_target_branch: nil,
      tracker_required_reviewers: nil
    )

    configure_git_origin!(
      Path.dirname(Workflow.workflow_file_path()),
      "https://dev.azure.com/openai/Symphony/_git/inferred-repo"
    )

    orchestrator_name = Module.concat(__MODULE__, :AzureRepoSettingsOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot(), refresh: :ok})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Azure Repos settings"
    assert html =~ "Save `repository` and `target_branch` in `WORKFLOW.md`"
    assert html =~ "inferred-repo"

    render_submit(view, "save_azure_repo_settings", %{
      "azure_repo_settings" => %{
        "repository" => "manual-repo",
        "target_branch" => "release/2026",
        "required_reviewers" => "alice@example.com\nbob@example.com"
      }
    })

    updated_html = render(view)
    assert updated_html =~ "manual-repo"
    assert updated_html =~ "release/2026"
    assert Config.azure_devops_repository() == "manual-repo"
    assert Config.azure_devops_target_branch() == "release/2026"
    assert Config.azure_devops_required_reviewers() == ["alice@example.com", "bob@example.com"]

    persisted_workflow = File.read!(Workflow.workflow_file_path())
    assert persisted_workflow =~ ~s(repository: "manual-repo")
    assert persisted_workflow =~ ~s(target_branch: "release/2026")
    refute persisted_workflow =~ "repository: \"inferred-repo\""
  end

  test "dashboard liveview lets operators edit persisted azure repo settings later" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_repository: "old-repo",
      tracker_target_branch: "main",
      tracker_required_reviewers: ["alice@example.com"]
    )

    orchestrator_name = Module.concat(__MODULE__, :AzureRepoEditOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot(), refresh: :ok})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "old-repo"
    assert html =~ "main"
    assert html =~ "alice@example.com"

    render_submit(view, "save_azure_repo_settings", %{
      "azure_repo_settings" => %{
        "repository" => "new-repo",
        "target_branch" => "stable",
        "required_reviewers" => "carol@example.com"
      }
    })

    updated_html = render(view)
    assert updated_html =~ "new-repo"
    assert updated_html =~ "stable"
    assert updated_html =~ "carol@example.com"
    assert Config.azure_devops_repository() == "new-repo"
    assert Config.azure_devops_target_branch() == "stable"
    assert Config.azure_devops_required_reviewers() == ["carol@example.com"]
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp configure_git_origin!(dir, remote_url) do
    {_, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    _ = System.cmd("git", ["remote", "remove", "origin"], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", remote_url], cd: dir, stderr_to_stdout: true)
  end

  defp stop_workflow_store! do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

      _ ->
        :ok
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
