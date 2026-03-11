defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "tool_specs advertises the azure_devops_request input contract for azure workflows" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "body" => _,
                   "method" => %{"enum" => ["GET", "POST", "PUT", "PATCH", "DELETE"]},
                   "path" => _,
                   "query" => _
                 },
                 "required" => ["method", "path"],
                 "type" => "object"
               },
               "name" => "azure_devops_request"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Azure DevOps"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }
  end

  test "unsupported tools on azure workflows return the azure dynamic tool in supportedTools" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    response = DynamicTool.execute("not_a_real_tool", %{})

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["azure_devops_request"]
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end

  test "azure_devops_request validates required arguments before calling the client" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    assert_invalid_azure_request(
      %{"path" => "/Symphony/_apis/git/repositories"},
      %{
        "error" => %{
          "message" => "`azure_devops_request` requires a non-empty `method` string."
        }
      }
    )

    assert_invalid_azure_request(
      %{"method" => "trace", "path" => "/Symphony/_apis/git/repositories"},
      %{
        "error" => %{
          "message" => "`azure_devops_request.method` must be one of GET, POST, PUT, PATCH, DELETE."
        }
      }
    )

    assert_invalid_azure_request(
      %{"method" => "GET"},
      %{
        "error" => %{
          "message" => "`azure_devops_request` requires a non-empty `path` string."
        }
      }
    )

    assert_invalid_azure_request(
      %{"method" => "GET", "path" => "repositories"},
      %{
        "error" => %{
          "message" => "`azure_devops_request.path` must be a relative path starting with `/` or an absolute URL on the configured Azure DevOps endpoint, without query string or fragment."
        }
      }
    )

    assert_invalid_azure_request(
      %{"method" => "GET", "path" => "/Symphony/_apis/git/repositories?api-version=7.1"},
      %{
        "error" => %{
          "message" => "`azure_devops_request.path` must be a relative path starting with `/` or an absolute URL on the configured Azure DevOps endpoint, without query string or fragment."
        }
      }
    )

    assert_invalid_azure_request(
      %{"method" => "GET", "path" => "/Symphony/_apis/git/repositories", "query" => ["bad"]},
      %{
        "error" => %{
          "message" => "`azure_devops_request.query` must be a JSON object when provided."
        }
      }
    )

    assert_invalid_azure_request(
      %{
        "method" => "POST",
        "path" => "/Symphony/_apis/git/repositories",
        "body" => %{payload: self()}
      },
      %{
        "error" => %{
          "message" => "`azure_devops_request.body` must be valid JSON when provided."
        }
      }
    )
  end

  test "azure_devops_request rejects cross-host absolute URLs before calling the client" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    response =
      DynamicTool.execute(
        "azure_devops_request",
        %{"method" => "GET", "path" => "https://example.com/openai/_apis/git/repositories"},
        azure_devops_client: fn _method, _path, _request_opts ->
          flunk("azure client should not be called when the request path is cross-host")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`azure_devops_request.path` must stay on the configured Azure DevOps endpoint.",
               "configuredEndpoint" => "https://dev.azure.com/openai",
               "requestPath" => "https://example.com/openai/_apis/git/repositories"
             }
           }
  end

  test "azure_devops_request formats missing auth and transport failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    missing_token =
      DynamicTool.execute(
        "azure_devops_request",
        %{"method" => "GET", "path" => "/Symphony/_apis/git/repositories"}
      )

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Azure DevOps auth. Set `tracker.api_key` in `WORKFLOW.md` or export `AZURE_DEVOPS_TOKEN`."
             }
           }

    request_error =
      DynamicTool.execute(
        "azure_devops_request",
        %{"method" => "GET", "path" => "/Symphony/_apis/git/repositories"},
        azure_devops_client: fn _method, _path, _request_opts ->
          {:error, {:azure_devops_api_request, :timeout}}
        end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Azure DevOps request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "azure_devops_request formats non-2xx responses" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    response =
      DynamicTool.execute(
        "azure_devops_request",
        %{"method" => "PATCH", "path" => "/Symphony/_apis/git/pullrequests/42"},
        azure_devops_client: fn _method, _path, _request_opts ->
          {:error, {:azure_devops_api_status, 409}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Azure DevOps request failed with HTTP 409.",
               "status" => 409
             }
           }
  end

  test "azure_devops_request forwards normalized requests and returns JSON payloads" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "azure_devops",
      tracker_endpoint: "https://dev.azure.com/openai",
      tracker_api_token: "azure-token",
      tracker_project_slug: nil,
      tracker_project: "Symphony"
    )

    test_pid = self()

    response =
      DynamicTool.execute(
        "azure_devops_request",
        %{
          "method" => "post",
          "path" => "https://dev.azure.com/openai/Symphony/_apis/git/repositories",
          "query" => %{searchText: "symphony", includeHidden: false},
          "body" => %{sourceRefName: "refs/heads/main", reviewers: [%{id: 123}]}
        },
        azure_devops_client: fn method, path, request_opts ->
          send(test_pid, {:azure_client_called, method, path, request_opts})
          {:ok, %{"value" => [%{"id" => "repo-123", "name" => "symphony"}]}}
        end
      )

    assert_received {:azure_client_called, :post, "/Symphony/_apis/git/repositories",
                     %{
                       body: %{
                         "reviewers" => [%{"id" => 123}],
                         "sourceRefName" => "refs/heads/main"
                       },
                       query: %{
                         "includeHidden" => false,
                         "searchText" => "symphony"
                       }
                     }}

    assert response["success"] == true

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "value" => [%{"id" => "repo-123", "name" => "symphony"}]
           }
  end

  defp assert_invalid_azure_request(arguments, expected_payload) do
    response =
      DynamicTool.execute(
        "azure_devops_request",
        arguments,
        azure_devops_client: fn _method, _path, _request_opts ->
          flunk("azure client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == expected_payload
  end
end
