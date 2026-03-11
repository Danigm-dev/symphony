defmodule SymphonyElixir.AzureDevOpsAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AzureDevOps.{Adapter, Client}

  defmodule FakeAzureClient do
    def fetch_candidate_issues do
      send(self(), :azure_fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:azure_fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:azure_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def create_comment(issue_id, body) do
      send(self(), {:azure_create_comment_called, issue_id, body})
      Process.get({__MODULE__, :create_comment_result}, {:ok, %{"commentId" => 1}})
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:azure_update_issue_state_called, issue_id, state_name})

      Process.get(
        {__MODULE__, :update_issue_state_result},
        {:ok, %{"fields" => %{"System.State" => state_name}}}
      )
    end
  end

  test "azure adapter delegates read methods and successful writes to configured client module" do
    Application.put_env(:symphony_elixir, :azure_devops_client_module, FakeAzureClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :azure_devops_client_module)
      Process.delete({FakeAzureClient, :create_comment_result})
      Process.delete({FakeAzureClient, :update_issue_state_result})
    end)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :azure_fetch_candidate_issues_called

    assert {:ok, ["Active"]} = Adapter.fetch_issues_by_states(["Active"])
    assert_receive {:azure_fetch_issues_by_states_called, ["Active"]}

    assert {:ok, ["123"]} = Adapter.fetch_issue_states_by_ids(["123"])
    assert_receive {:azure_fetch_issue_states_by_ids_called, ["123"]}

    assert :ok = Adapter.create_comment("123", "tracking update")
    assert_receive {:azure_create_comment_called, "123", "tracking update"}

    assert :ok = Adapter.update_issue_state("123", "Done")
    assert_receive {:azure_update_issue_state_called, "123", "Done"}
  end

  test "azure adapter returns structured errors for write path failures" do
    Application.put_env(:symphony_elixir, :azure_devops_client_module, FakeAzureClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :azure_devops_client_module)
      Process.delete({FakeAzureClient, :create_comment_result})
      Process.delete({FakeAzureClient, :update_issue_state_result})
    end)

    Process.put({FakeAzureClient, :create_comment_result}, {:ok, %{"text" => "missing id"}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("123", "broken")

    Process.put({FakeAzureClient, :create_comment_result}, {:error, :azure_boom})
    assert {:error, :azure_boom} = Adapter.create_comment("123", "boom")

    Process.put({FakeAzureClient, :update_issue_state_result}, {:ok, %{"fields" => %{"System.State" => "Other"}}})
    assert {:error, :issue_update_failed} = Adapter.update_issue_state("123", "Done")

    Process.put({FakeAzureClient, :update_issue_state_result}, {:error, :azure_boom})
    assert {:error, :azure_boom} = Adapter.update_issue_state("123", "Done")
  end

  test "azure client uses configured wiql and normalizes hydrated work items" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_assignee: "me",
      tracker_wiql: "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = 'Symphony'"
    )

    request_fun = fn method, path, request_opts ->
      request_number = Process.get(:azure_request_number, 0) + 1
      Process.put(:azure_request_number, request_number)
      send(self(), {:azure_request, request_number, method, path, request_opts})

      case request_number do
        1 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "authenticatedUser" => %{
                 "id" => "user-1",
                 "uniqueName" => "azure.user@example.com"
               }
             }
           }}

        2 ->
          {:ok, %{status: 200, body: %{"workItems" => [%{"id" => 101}]}}}

        3 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "value" => [
                 %{
                   "id" => 101,
                   "fields" => %{
                     "System.Title" => "Investigate Azure polling",
                     "System.Description" => "Reproduce and normalize work items",
                     "System.State" => "Active",
                     "System.AssignedTo" => %{
                       "id" => "user-1",
                       "uniqueName" => "azure.user@example.com"
                     },
                     "System.Tags" => "Backend; Infra",
                     "System.CreatedDate" => "2026-03-10T09:00:00Z",
                     "System.ChangedDate" => "2026-03-11T10:30:00Z",
                     "Microsoft.VSTS.Common.Priority" => 1,
                     "Microsoft.VSTS.CodeReview.SourceBranch" => "refs/heads/feature/azure-boards"
                   },
                   "_links" => %{
                     "html" => %{
                       "href" => "https://dev.azure.com/openai/Symphony/_workitems/edit/101"
                     }
                   },
                   "relations" => [
                     %{
                       "rel" => "System.LinkTypes.Dependency-Reverse",
                       "url" => "https://dev.azure.com/openai/_apis/wit/workItems/202"
                     }
                   ]
                 }
               ]
             }
           }}

        4 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "value" => [
                 %{
                   "id" => 202,
                   "fields" => %{
                     "System.Title" => "Blocked prerequisite",
                     "System.State" => "New"
                   }
                 }
               ]
             }
           }}
      end
    end

    assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

    assert issue.id == "101"
    assert issue.identifier == "AB#101"
    assert issue.title == "Investigate Azure polling"
    assert issue.description == "Reproduce and normalize work items"
    assert issue.state == "Active"
    assert issue.priority == 1
    assert issue.branch_name == "refs/heads/feature/azure-boards"
    assert issue.url == "https://dev.azure.com/openai/Symphony/_workitems/edit/101"
    assert issue.assignee_id == "user-1"
    assert issue.labels == ["backend", "infra"]
    assert issue.assigned_to_worker
    assert issue.blocked_by == [%{id: "202", identifier: "AB#202", state: "New"}]
    assert issue.created_at == DateTime.from_naive!(~N[2026-03-10 09:00:00], "Etc/UTC")
    assert issue.updated_at == DateTime.from_naive!(~N[2026-03-11 10:30:00], "Etc/UTC")

    assert_receive {:azure_request, 1, :get, "/_apis/connectionData", connection_opts}
    assert connection_opts.query["api-version"] == "7.1"

    assert_receive {:azure_request, 2, :post, "/Symphony/_apis/wit/wiql", wiql_opts}
    assert wiql_opts.body["query"] == "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = 'Symphony'"

    assert_receive {:azure_request, 3, :post, "/Symphony/_apis/wit/workitemsbatch", batch_opts}
    assert batch_opts.body["ids"] == [101]
    assert batch_opts.body["$expand"] == "Relations"

    assert_receive {:azure_request, 4, :post, "/Symphony/_apis/wit/workitemsbatch", blocker_opts}
    assert blocker_opts.body["ids"] == [202]
  end

  test "azure client builds wiql from states and configured filters" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_assignee: nil,
      tracker_work_item_types: ["User Story", "Bug"],
      tracker_area_paths: ["Platform", "Agents"],
      tracker_iteration_path: "FY26\\Sprint 1",
      tracker_wiql: nil
    )

    request_fun = fn :post, "/Symphony/_apis/wit/wiql", request_opts ->
      send(self(), {:azure_wiql_request, request_opts})
      {:ok, %{status: 200, body: %{"workItems" => []}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_states(["New", "Active"], request_fun: request_fun)

    assert_receive {:azure_wiql_request, request_opts}

    wiql = request_opts.body["query"]
    assert wiql =~ "[System.TeamProject] = 'Symphony'"
    assert wiql =~ "[System.State] IN ('New', 'Active')"
    assert wiql =~ "[System.WorkItemType] IN ('User Story', 'Bug')"
    assert wiql =~ "[System.AreaPath] UNDER 'Platform'"
    assert wiql =~ "[System.AreaPath] UNDER 'Agents'"
    assert wiql =~ "[System.IterationPath] = 'FY26\\Sprint 1'"
  end

  test "azure client fetches issue states by ids and handles missing optional fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_assignee: "me"
    )

    request_fun = fn method, path, request_opts ->
      request_number = Process.get(:azure_state_request_number, 0) + 1
      Process.put(:azure_state_request_number, request_number)
      send(self(), {:azure_state_request, request_number, method, path, request_opts})

      case request_number do
        1 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "authenticatedUser" => %{
                 "uniqueName" => "azure.user@example.com"
               }
             }
           }}

        2 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "value" => [
                 %{
                   "id" => 303,
                   "fields" => %{
                     "System.Title" => "Minimal work item",
                     "System.State" => "Closed",
                     "System.AssignedTo" => %{
                       "uniqueName" => "someone.else@example.com"
                     }
                   }
                 }
               ]
             }
           }}
      end
    end

    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["303"], request_fun: request_fun)

    assert issue.id == "303"
    assert issue.identifier == "AB#303"
    assert issue.title == "Minimal work item"
    assert issue.state == "Closed"
    assert issue.url == "https://dev.azure.com/openai/Symphony/_workitems/edit/303"
    assert issue.labels == []
    assert issue.blocked_by == []
    assert issue.priority == nil
    assert issue.created_at == nil
    assert issue.updated_at == nil
    refute issue.assigned_to_worker
  end

  test "azure client updates work item state and exposes comment primitives" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_assignee: nil
    )

    request_fun = fn method, path, request_opts ->
      request_number = Process.get(:azure_write_request_number, 0) + 1
      Process.put(:azure_write_request_number, request_number)
      send(self(), {:azure_write_request, request_number, method, path, request_opts})

      case request_number do
        1 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => 101,
               "fields" => %{"System.State" => "Done"}
             }
           }}

        2 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "commentId" => 88,
               "text" => "## Codex Workpad\ncreated"
             }
           }}

        3 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "comments" => [
                 %{"commentId" => 88, "text" => "## Codex Workpad\ncreated"}
               ],
               "continuationToken" => "page-2"
             }
           }}

        4 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "comments" => [
                 %{"commentId" => 89, "text" => "other comment"}
               ]
             }
           }}

        5 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "commentId" => 88,
               "text" => "## Codex Workpad\nupdated"
             }
           }}
      end
    end

    assert {:ok, %{"fields" => %{"System.State" => "Done"}}} =
             Client.update_issue_state("101", "Done", request_fun: request_fun)

    assert {:ok, %{"commentId" => 88, "text" => "## Codex Workpad\ncreated"}} =
             Client.create_comment("101", "## Codex Workpad\ncreated", request_fun: request_fun)

    assert {:ok,
            [
              %{"commentId" => 88, "text" => "## Codex Workpad\ncreated"},
              %{"commentId" => 89, "text" => "other comment"}
            ]} = Client.list_comments("101", request_fun: request_fun)

    assert {:ok, %{"commentId" => 88, "text" => "## Codex Workpad\nupdated"}} =
             Client.update_comment("101", 88, "## Codex Workpad\nupdated", request_fun: request_fun)

    assert_receive {:azure_write_request, 1, :patch, "/Symphony/_apis/wit/workitems/101", state_opts}
    assert state_opts.body == [%{"op" => "add", "path" => "/fields/System.State", "value" => "Done"}]
    assert state_opts.query["api-version"] == "7.1"
    assert header_value(state_opts.headers, "content-type") == "application/json-patch+json"
    assert String.starts_with?(header_value(state_opts.headers, "authorization"), "Basic ")

    assert_receive {:azure_write_request, 2, :post, "/Symphony/_apis/wit/workItems/101/comments", create_comment_opts}
    assert create_comment_opts.body == %{"text" => "## Codex Workpad\ncreated"}
    assert create_comment_opts.query["format"] == "markdown"
    assert create_comment_opts.query["api-version"] == "7.1-preview.4"

    assert_receive {:azure_write_request, 3, :get, "/Symphony/_apis/wit/workItems/101/comments", list_comments_opts}
    assert list_comments_opts.query["$top"] == 200
    assert list_comments_opts.query["api-version"] == "7.1-preview.4"
    refute Map.has_key?(list_comments_opts.query, "continuationToken")

    assert_receive {:azure_write_request, 4, :get, "/Symphony/_apis/wit/workItems/101/comments", next_page_opts}
    assert next_page_opts.query["continuationToken"] == "page-2"

    assert_receive {:azure_write_request, 5, :patch, "/Symphony/_apis/wit/workItems/101/comments/88", update_comment_opts}
    assert update_comment_opts.body == %{"text" => "## Codex Workpad\nupdated"}
    assert update_comment_opts.query["format"] == "markdown"
    assert update_comment_opts.query["api-version"] == "7.1-preview.4"
    assert header_value(update_comment_opts.headers, "content-type") == "application/json"
  end

  test "azure client returns structured write path errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_assignee: nil
    )

    assert {:error, :invalid_issue_id} =
             Client.update_issue_state("   ", "Done", request_fun: fn _, _, _ -> flunk("unexpected request") end)

    assert {:error, :invalid_state_name} =
             Client.update_issue_state("101", "   ", request_fun: fn _, _, _ -> flunk("unexpected request") end)

    assert {:error, :invalid_comment_text} =
             Client.create_comment("101", "   ", request_fun: fn _, _, _ -> flunk("unexpected request") end)

    assert {:error, :invalid_comment_id} =
             Client.update_comment("101", "   ", "body", request_fun: fn _, _, _ -> flunk("unexpected request") end)

    error_request_fun = fn _method, _path, _request_opts ->
      {:ok, %{status: 409, body: %{"message" => "conflict"}}}
    end

    assert {:error, {:azure_devops_api_status, 409}} =
             Client.update_issue_state("101", "Done", request_fun: error_request_fun)

    assert {:error, {:azure_devops_api_status, 409}} =
             Client.create_comment("101", "body", request_fun: error_request_fun)

    unknown_payload_fun = fn :get, _path, _request_opts ->
      {:ok, %{status: 200, body: %{"count" => 1}}}
    end

    assert {:error, :azure_devops_unknown_payload} =
             Client.list_comments("101", request_fun: unknown_payload_fun)
  end

  test "azure client write primitives fail structurally when api token is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_project: "Symphony",
      tracker_assignee: nil
    )

    request_fun = fn _, _, _ -> flunk("unexpected request") end

    assert {:error, :missing_azure_devops_api_token} =
             Client.update_issue_state("101", "Done", request_fun: request_fun)

    assert {:error, :missing_azure_devops_api_token} =
             Client.create_comment("101", "body", request_fun: request_fun)

    assert {:error, :missing_azure_devops_api_token} =
             Client.list_comments("101", request_fun: request_fun)

    assert {:error, :missing_azure_devops_api_token} =
             Client.update_comment("101", 88, "body", request_fun: request_fun)
  end

  defp header_value(headers, expected_name) when is_list(headers) and is_binary(expected_name) do
    expected_name = String.downcase(expected_name)

    headers
    |> Enum.find_value(fn {header_name, header_value} ->
      if String.downcase(header_name) == expected_name, do: header_value
    end)
  end
end
