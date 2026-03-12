defmodule SymphonyElixir.AzureDevOps.Client do
  @moduledoc """
  Thin Azure DevOps REST client for polling and mutating Azure Boards work items.
  """

  require Logger

  alias SymphonyElixir.{Config, Issue}

  @batch_size 200
  @max_error_body_log_bytes 1_000
  @comments_api_version "7.1-preview.4"
  @comment_format "markdown"
  @work_item_fields [
    "System.Title",
    "System.Description",
    "System.State",
    "System.AssignedTo",
    "System.Tags",
    "System.CreatedDate",
    "System.ChangedDate",
    "Microsoft.VSTS.Common.Priority",
    "Microsoft.VSTS.CodeReview.SourceBranch",
    "System.BranchName"
  ]
  @work_item_expand "Relations"
  @connection_data_path "/_apis/connectionData"

  @type request_opts :: %{
          optional(:body) => map() | [map()] | nil,
          optional(:headers) => [{String.t(), String.t()}],
          optional(:query) => map()
        }
  @type request_response :: %{
          required(:status) => integer(),
          required(:body) => term(),
          optional(:headers) => term()
        }
  @type request_fun ::
          (atom(), String.t(), request_opts() -> {:ok, request_response()} | {:error, term()})
  @type assignee_filter :: %{configured_assignee: String.t(), match_values: MapSet.t(String.t())}

  @spec raw_request(atom(), String.t(), request_opts()) :: {:ok, term()} | {:error, term()}
  def raw_request(method, path, request_opts \\ %{})

  @spec raw_request(atom(), String.t(), request_opts()) :: {:ok, term()} | {:error, term()}
  def raw_request(method, path, request_opts)
      when is_atom(method) and is_binary(path) and is_map(request_opts) do
    with :ok <- require_api_token() do
      request(method, path, request_opts, [])
    end
  end

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    with :ok <- require_api_token(),
         {:ok, assignee_filter} <- routing_assignee_filter(opts),
         {:ok, issue_ids} <- query_by_wiql(candidate_wiql(), opts) do
      hydrate_work_items(issue_ids, assignee_filter, opts)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    normalized_state_names =
      state_names
      |> Enum.map(&normalize_non_empty_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case normalized_state_names do
      [] ->
        {:ok, []}

      states ->
        with :ok <- require_api_token(),
             {:ok, issue_ids} <- query_by_wiql(build_wiql(states, nil), opts) do
          hydrate_work_items(issue_ids, nil, opts)
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    normalized_ids =
      issue_ids
      |> Enum.map(&normalize_issue_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case normalized_ids do
      [] ->
        {:ok, []}

      ids ->
        with :ok <- require_api_token(),
             {:ok, assignee_filter} <- routing_assignee_filter(opts) do
          hydrate_work_items(ids, assignee_filter, opts)
        end
    end
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    with :ok <- require_api_token(),
         {:ok, normalized_issue_id} <- require_issue_id(issue_id),
         {:ok, comment_text} <- require_comment_text(body) do
      request(
        :post,
        comments_path(normalized_issue_id),
        %{
          body: %{"text" => comment_text},
          query: %{
            "format" => @comment_format,
            "api-version" => @comments_api_version
          }
        },
        opts
      )
    end
  end

  @spec list_comments(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(issue_id, opts \\ []) when is_binary(issue_id) do
    with :ok <- require_api_token(),
         {:ok, normalized_issue_id} <- require_issue_id(issue_id) do
      do_list_comments(normalized_issue_id, nil, [], opts)
    end
  end

  @spec update_comment(String.t(), String.t() | integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_comment(issue_id, comment_id, body, opts \\ [])
      when is_binary(issue_id) and is_binary(body) do
    with :ok <- require_api_token(),
         {:ok, normalized_issue_id} <- require_issue_id(issue_id),
         {:ok, normalized_comment_id} <- require_comment_id(comment_id),
         {:ok, comment_text} <- require_comment_text(body) do
      request(
        :patch,
        comment_path(normalized_issue_id, normalized_comment_id),
        %{
          body: %{"text" => comment_text},
          query: %{
            "format" => @comment_format,
            "api-version" => @comments_api_version
          }
        },
        opts
      )
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_issue_state(issue_id, state_name, opts \\ [])
      when is_binary(issue_id) and is_binary(state_name) do
    with :ok <- require_api_token(),
         {:ok, normalized_issue_id} <- require_issue_id(issue_id),
         {:ok, normalized_state_name} <- require_state_name(state_name) do
      request(
        :patch,
        project_path("/_apis/wit/workitems/" <> encode_path_segment(normalized_issue_id)),
        %{
          body: [
            %{
              "op" => "add",
              "path" => "/fields/System.State",
              "value" => normalized_state_name
            }
          ],
          headers: [{"Content-Type", "application/json-patch+json"}]
        },
        opts
      )
    end
  end

  @doc false
  @spec normalize_work_item_for_test(term(), map(), term()) :: Issue.t() | nil
  def normalize_work_item_for_test(work_item, blockers_by_id \\ %{}, assignee \\ nil) do
    assignee_filter = assignee_filter_for_test(assignee)
    normalize_work_item(work_item, blockers_by_id, assignee_filter)
  end

  @doc false
  @spec build_wiql_for_test([String.t()], String.t() | nil) :: String.t()
  def build_wiql_for_test(state_names, assignee \\ nil) when is_list(state_names) do
    build_wiql(state_names, assignee)
  end

  @doc false
  @spec assigned_to_worker_for_test(term(), term()) :: boolean()
  def assigned_to_worker_for_test(assignee, assignee_filter) do
    assigned_to_worker?(assignee, assignee_filter)
  end

  @doc false
  @spec extract_branch_name_for_test(term(), term()) :: String.t() | nil
  def extract_branch_name_for_test(fields, relations \\ nil), do: extract_branch_name(fields, relations)

  @doc false
  @spec azure_id_for_request_for_test(term()) :: term()
  def azure_id_for_request_for_test(issue_id), do: azure_id_for_request(issue_id)

  @doc false
  @spec encode_path_segment_for_test(term()) :: String.t()
  def encode_path_segment_for_test(value), do: encode_path_segment(value)

  defp require_api_token do
    if is_binary(Config.azure_devops_api_token()) do
      :ok
    else
      {:error, :missing_azure_devops_api_token}
    end
  end

  defp candidate_wiql do
    case Config.azure_devops_wiql() do
      wiql when is_binary(wiql) -> wiql
      _ -> build_wiql(Config.azure_devops_active_states(), Config.azure_devops_assignee())
    end
  end

  defp build_wiql(state_names, configured_assignee) do
    conditions =
      [
        "[System.TeamProject] = #{wiql_string(Config.azure_devops_project())}",
        state_clause(state_names),
        work_item_type_clause(Config.azure_devops_work_item_types()),
        area_path_clause(Config.azure_devops_area_paths()),
        iteration_path_clause(Config.azure_devops_iteration_path()),
        assignee_clause(configured_assignee)
      ]
      |> Enum.reject(&is_nil/1)

    """
    SELECT [System.Id]
    FROM WorkItems
    WHERE #{Enum.join(conditions, " AND ")}
    ORDER BY [Microsoft.VSTS.Common.Priority] ASC, [System.CreatedDate] ASC
    """
    |> String.trim()
  end

  defp state_clause(state_names) when is_list(state_names) do
    normalized_state_names =
      state_names
      |> Enum.map(&normalize_non_empty_string/1)
      |> Enum.reject(&is_nil/1)

    if normalized_state_names == [] do
      nil
    else
      "[System.State] IN (#{Enum.map_join(normalized_state_names, ", ", &wiql_string/1)})"
    end
  end

  defp work_item_type_clause([]), do: nil

  defp work_item_type_clause(work_item_types) when is_list(work_item_types) do
    "[System.WorkItemType] IN (#{Enum.map_join(work_item_types, ", ", &wiql_string/1)})"
  end

  defp area_path_clause([]), do: nil

  defp area_path_clause(area_paths) when is_list(area_paths) do
    clauses =
      Enum.map(area_paths, fn area_path ->
        "[System.AreaPath] UNDER #{wiql_string(area_path)}"
      end)

    "(" <> Enum.join(clauses, " OR ") <> ")"
  end

  defp iteration_path_clause(nil), do: nil

  defp iteration_path_clause(iteration_path) when is_binary(iteration_path) do
    "[System.IterationPath] = #{wiql_string(iteration_path)}"
  end

  defp assignee_clause(nil), do: nil

  defp assignee_clause(configured_assignee) when is_binary(configured_assignee) do
    case normalize_non_empty_string(configured_assignee) do
      nil ->
        nil

      "me" ->
        "[System.AssignedTo] = @Me"

      normalized_assignee ->
        "[System.AssignedTo] = #{wiql_string(normalized_assignee)}"
    end
  end

  defp wiql_string(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp query_by_wiql(wiql, opts) when is_binary(wiql) do
    with {:ok, body} <- request(:post, project_path("/_apis/wit/wiql"), %{body: %{"query" => wiql}}, opts) do
      extract_wiql_ids(body)
    end
  end

  defp extract_wiql_ids(%{"workItems" => work_items}) when is_list(work_items) do
    ids =
      work_items
      |> Enum.map(&normalize_issue_id(Map.get(&1, "id")))
      |> Enum.reject(&is_nil/1)

    {:ok, ids}
  end

  defp extract_wiql_ids(%{"workItems" => nil}), do: {:ok, []}
  defp extract_wiql_ids(_unknown), do: {:error, :azure_devops_unknown_payload}

  defp hydrate_work_items([], _assignee_filter, _opts), do: {:ok, []}

  defp hydrate_work_items(issue_ids, assignee_filter, opts) when is_list(issue_ids) do
    with {:ok, primary_items_by_id} <- fetch_work_items_by_ids(issue_ids, opts),
         {:ok, blocker_items_by_id} <- fetch_blocker_items(primary_items_by_id, opts) do
      lookup = Map.merge(blocker_items_by_id, primary_items_by_id)

      issues =
        issue_ids
        |> Enum.map(&Map.get(primary_items_by_id, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&normalize_work_item(&1, lookup, assignee_filter))
        |> Enum.reject(&is_nil/1)

      {:ok, issues}
    end
  end

  defp fetch_work_items_by_ids(issue_ids, opts) when is_list(issue_ids) do
    items =
      issue_ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while({:ok, %{}}, fn issue_id_chunk, {:ok, acc} ->
        fetch_work_item_chunk(issue_id_chunk, acc, opts)
      end)

    case items do
      {:ok, items_by_id} -> {:ok, items_by_id}
      other -> other
    end
  end

  defp fetch_blocker_items(primary_items_by_id, opts) when is_map(primary_items_by_id) do
    blocker_ids =
      primary_items_by_id
      |> Map.values()
      |> Enum.flat_map(&extract_blocker_ids_from_relations/1)
      |> Enum.reject(&Map.has_key?(primary_items_by_id, &1))
      |> Enum.uniq()

    case blocker_ids do
      [] -> {:ok, %{}}
      ids -> fetch_work_items_by_ids(ids, opts)
    end
  end

  defp routing_assignee_filter(opts) do
    case Config.azure_devops_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee, request_fun(opts), opts)
    end
  end

  defp build_assignee_filter(assignee, _request_fun, _opts \\ [])

  defp build_assignee_filter(assignee, request_fun, opts) when is_binary(assignee) do
    case normalize_non_empty_string(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_current_user_filter(request_fun, opts)

      normalized_assignee ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized_assignee])}}
    end
  end

  defp resolve_current_user_filter(request_fun, _opts) do
    request_opts = %{
      headers: azure_devops_headers(),
      query: %{
        "api-version" => Config.azure_devops_api_version(),
        "connectOptions" => "none",
        "lastChangeId" => "-1",
        "lastChangeId64" => "-1"
      }
    }

    case request_fun.(:get, @connection_data_path, request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        build_current_user_filter(get_in(body, ["authenticatedUser"]))

      {:ok, response} ->
        Logger.error(
          "Azure DevOps request failed status=#{response.status}" <>
            azure_devops_error_context(@connection_data_path, response)
        )

        {:error, {:azure_devops_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Azure DevOps request failed: #{inspect(reason)}")
        {:error, {:azure_devops_api_request, reason}}
    end
  end

  defp normalize_work_item(work_item, blockers_by_id, assignee_filter)
       when is_map(work_item) and is_map(blockers_by_id) do
    issue_id = normalize_issue_id(work_item["id"])
    fields = Map.get(work_item, "fields", %{})
    assignee = Map.get(fields, "System.AssignedTo")

    %Issue{
      id: issue_id,
      identifier: issue_identifier(issue_id),
      title: Map.get(fields, "System.Title"),
      description: Map.get(fields, "System.Description"),
      priority: parse_priority(Map.get(fields, "Microsoft.VSTS.Common.Priority")),
      state: Map.get(fields, "System.State"),
      branch_name: extract_branch_name(fields, Map.get(work_item, "relations")),
      url: extract_url(work_item, issue_id),
      assignee_id: assignee_identity_id(assignee),
      blocked_by: extract_blockers(work_item, blockers_by_id),
      labels: extract_labels(fields),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(Map.get(fields, "System.CreatedDate")),
      updated_at: parse_datetime(Map.get(fields, "System.ChangedDate"))
    }
  end

  defp normalize_work_item(_work_item, _blockers_by_id, _assignee_filter), do: nil

  defp extract_blockers(%{"relations" => relations}, blockers_by_id) when is_list(relations) and is_map(blockers_by_id) do
    relations
    |> Enum.flat_map(&extract_blocker_relation(&1, blockers_by_id))
    |> Enum.uniq_by(& &1.id)
  end

  defp extract_blockers(_work_item, _blockers_by_id), do: []

  defp blocker_issue_state(%{"fields" => fields}) when is_map(fields), do: Map.get(fields, "System.State")
  defp blocker_issue_state(_blocker_issue), do: nil

  defp assignee_filter_for_test(assignee) when is_binary(assignee) do
    case build_assignee_filter(assignee, fn _, _, _ -> {:error, :not_available_for_test} end) do
      {:ok, filter} -> filter
      {:error, _reason} -> nil
    end
  end

  defp assignee_filter_for_test(_assignee), do: nil

  defp fetch_work_item_chunk(issue_id_chunk, acc, opts) do
    issue_id_chunk
    |> work_items_batch_request()
    |> then(&request(:post, project_path("/_apis/wit/workitemsbatch"), &1, opts))
    |> case do
      {:ok, %{"value" => work_items}} when is_list(work_items) ->
        {:cont, {:ok, merge_work_items_by_id(acc, work_items)}}

      {:ok, _body} ->
        {:halt, {:error, :azure_devops_unknown_payload}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp work_items_batch_request(issue_id_chunk) do
    %{
      body: %{
        "ids" => Enum.map(issue_id_chunk, &azure_id_for_request/1),
        "fields" => @work_item_fields,
        "$expand" => @work_item_expand,
        "errorPolicy" => "Omit"
      }
    }
  end

  defp merge_work_items_by_id(acc, work_items) do
    Enum.reduce(work_items, acc, fn work_item, items_acc ->
      case normalize_issue_id(work_item["id"]) do
        nil -> items_acc
        issue_id -> Map.put(items_acc, issue_id, work_item)
      end
    end)
  end

  defp build_current_user_filter(user) when is_map(user) do
    match_values =
      user
      |> assignee_identity_values()
      |> MapSet.new()

    if MapSet.size(match_values) == 0 do
      {:error, :missing_azure_devops_authenticated_identity}
    else
      {:ok, %{configured_assignee: "me", match_values: match_values}}
    end
  end

  defp build_current_user_filter(_user), do: {:error, :missing_azure_devops_authenticated_identity}

  defp extract_blocker_relation(relation, blockers_by_id) do
    if blocker_relation?(relation) do
      relation
      |> Map.get("url")
      |> parse_relation_work_item_id()
      |> build_blocker_payload(blockers_by_id)
    else
      []
    end
  end

  defp build_blocker_payload(nil, _blockers_by_id), do: []

  defp build_blocker_payload(blocker_id, blockers_by_id) do
    blocker_issue = Map.get(blockers_by_id, blocker_id)

    [
      %{
        id: blocker_id,
        identifier: issue_identifier(blocker_id),
        state: blocker_issue_state(blocker_issue)
      }
    ]
  end

  defp extract_blocker_ids_from_relations(%{"relations" => relations}) when is_list(relations) do
    relations
    |> Enum.filter(&blocker_relation?/1)
    |> Enum.map(&parse_relation_work_item_id(Map.get(&1, "url")))
    |> Enum.reject(&is_nil/1)
  end

  defp extract_blocker_ids_from_relations(_work_item), do: []

  defp blocker_relation?(%{"rel" => rel} = relation) when is_binary(rel) do
    normalized_rel = String.downcase(rel)
    normalized_name = normalize_non_empty_string(get_in(relation, ["attributes", "name"]))

    normalized_rel == "system.linktypes.dependency-reverse" or normalized_name == "predecessor"
  end

  defp blocker_relation?(_relation), do: false

  defp parse_relation_work_item_id(url) when is_binary(url) do
    case Regex.run(~r{/workItems/(\d+)$}, url, capture: :all_but_first) do
      [issue_id] -> issue_id
      _ -> nil
    end
  end

  defp parse_relation_work_item_id(_url), do: nil

  defp extract_labels(fields) when is_map(fields) do
    case Map.get(fields, "System.Tags") do
      tags when is_binary(tags) ->
        tags
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.downcase/1)

      _ ->
        []
    end
  end

  defp extract_branch_name(fields, _relations) when is_map(fields) do
    Map.get(fields, "Microsoft.VSTS.CodeReview.SourceBranch") ||
      Map.get(fields, "System.BranchName")
  end

  defp extract_branch_name(_fields, _relations), do: nil

  defp extract_url(work_item, issue_id) when is_map(work_item) do
    get_in(work_item, ["_links", "html", "href"]) || default_work_item_url(issue_id)
  end

  defp default_work_item_url(nil), do: nil

  defp default_work_item_url(issue_id) when is_binary(issue_id) do
    endpoint = Config.azure_devops_endpoint() |> String.trim_trailing("/")
    project = Config.azure_devops_project() |> encode_path_segment()
    endpoint <> "/" <> project <> "/_workitems/edit/" <> issue_id
  end

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(assignee, %{match_values: match_values}) when is_struct(match_values, MapSet) do
    assignee
    |> assignee_identity_values()
    |> Enum.any?(&MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_identity_values(%{} = assignee) do
    [
      Map.get(assignee, "id"),
      Map.get(assignee, "descriptor"),
      Map.get(assignee, "uniqueName"),
      Map.get(assignee, "mailAddress"),
      Map.get(assignee, "displayName")
    ]
    |> Enum.map(&normalize_non_empty_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp assignee_identity_values(value) when is_binary(value) do
    value
    |> normalize_non_empty_string()
    |> case do
      nil -> []
      normalized -> [normalized]
    end
  end

  defp assignee_identity_values(_value), do: []

  defp assignee_identity_id(%{} = assignee) do
    Map.get(assignee, "id") ||
      Map.get(assignee, "descriptor") ||
      Map.get(assignee, "uniqueName")
  end

  defp assignee_identity_id(value) when is_binary(value), do: value
  defp assignee_identity_id(_value), do: nil

  defp issue_identifier(issue_id) when is_binary(issue_id), do: "AB##{issue_id}"
  defp issue_identifier(_issue_id), do: nil

  defp azure_id_for_request(issue_id) when is_binary(issue_id) do
    case Integer.parse(issue_id) do
      {parsed_id, ""} -> parsed_id
      _ -> issue_id
    end
  end

  defp azure_id_for_request(issue_id), do: issue_id

  defp normalize_issue_id(issue_id) when is_integer(issue_id), do: Integer.to_string(issue_id)
  defp normalize_issue_id(issue_id) when is_binary(issue_id), do: normalize_non_empty_string(issue_id)
  defp normalize_issue_id(_issue_id), do: nil

  defp parse_priority(priority) when is_integer(priority), do: priority

  defp parse_priority(priority) when is_binary(priority) do
    case Integer.parse(String.trim(priority)) do
      {parsed_priority, ""} -> parsed_priority
      _ -> nil
    end
  end

  defp parse_priority(_priority), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp do_list_comments(issue_id, continuation_token, acc_comments, opts)
       when is_binary(issue_id) and is_list(acc_comments) do
    request_query =
      %{
        "$top" => @batch_size,
        "api-version" => @comments_api_version
      }
      |> maybe_put_continuation_token(continuation_token)

    case request(:get, comments_path(issue_id), %{query: request_query}, opts) do
      {:ok, %{"comments" => comments} = body} when is_list(comments) ->
        updated_comments = acc_comments ++ comments

        case next_comments_continuation_token(body) do
          nil -> {:ok, updated_comments}
          next_token -> do_list_comments(issue_id, next_token, updated_comments, opts)
        end

      {:ok, %{"comments" => nil}} ->
        {:ok, acc_comments}

      {:ok, _unknown} ->
        {:error, :azure_devops_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, path, request_opts, opts) when is_atom(method) and is_binary(path) and is_map(request_opts) and is_list(opts) do
    request_fun = request_fun(opts)

    request_headers =
      request_opts
      |> Map.get(:headers, [])
      |> merge_headers(azure_devops_headers())

    request_opts =
      request_opts
      |> Map.put(:headers, request_headers)
      |> Map.update(:query, %{"api-version" => Config.azure_devops_api_version()}, fn query ->
        Map.put_new(query, "api-version", Config.azure_devops_api_version())
      end)

    case request_fun.(method, path, request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, response} ->
        Logger.error(
          "Azure DevOps request failed status=#{response.status}" <>
            azure_devops_error_context(path, response)
        )

        {:error, {:azure_devops_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Azure DevOps request failed: #{inspect(reason)}")
        {:error, {:azure_devops_api_request, reason}}
    end
  end

  defp request_fun(opts) do
    Keyword.get(opts, :request_fun, &default_request/3)
  end

  defp azure_devops_headers do
    token = Config.azure_devops_api_token()
    encoded_credentials = Base.encode64(":" <> token)

    [
      {"Authorization", "Basic " <> encoded_credentials},
      {"Content-Type", "application/json"}
    ]
  end

  defp default_request(method, path, request_opts) do
    request_options =
      [
        method: method,
        url: build_url(path),
        headers: Map.get(request_opts, :headers, []),
        params: Map.get(request_opts, :query, %{}),
        connect_options: [timeout: 30_000]
      ]
      |> maybe_put_json_body(Map.get(request_opts, :body))

    Req.request(request_options)
  end

  defp maybe_put_json_body(request_options, nil), do: request_options
  defp maybe_put_json_body(request_options, body), do: Keyword.put(request_options, :json, body)

  defp merge_headers(custom_headers, default_headers)
       when is_list(custom_headers) and is_list(default_headers) do
    Enum.reduce(default_headers ++ custom_headers, [], fn {header_name, header_value}, headers_acc ->
      normalized_name = String.downcase(header_name)

      headers_acc
      |> Enum.reject(fn {existing_name, _existing_value} ->
        String.downcase(existing_name) == normalized_name
      end)
      |> Kernel.++([{header_name, header_value}])
    end)
  end

  defp build_url(path) when is_binary(path) do
    Config.azure_devops_endpoint()
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp project_path(path_suffix) when is_binary(path_suffix) do
    "/" <> encode_path_segment(Config.azure_devops_project()) <> path_suffix
  end

  defp comments_path(issue_id) when is_binary(issue_id) do
    project_path("/_apis/wit/workItems/" <> encode_path_segment(issue_id) <> "/comments")
  end

  defp comment_path(issue_id, comment_id) when is_binary(issue_id) and is_binary(comment_id) do
    comments_path(issue_id) <> "/" <> encode_path_segment(comment_id)
  end

  defp encode_path_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp encode_path_segment(_value), do: ""

  defp require_issue_id(issue_id) do
    case normalize_issue_id(issue_id) do
      nil -> {:error, :invalid_issue_id}
      normalized_issue_id -> {:ok, normalized_issue_id}
    end
  end

  defp require_comment_id(comment_id) do
    case normalize_issue_id(comment_id) do
      nil -> {:error, :invalid_comment_id}
      normalized_comment_id -> {:ok, normalized_comment_id}
    end
  end

  defp require_comment_text(comment_text) when is_binary(comment_text) do
    if String.trim(comment_text) == "" do
      {:error, :invalid_comment_text}
    else
      {:ok, comment_text}
    end
  end

  defp require_state_name(state_name) do
    case normalize_non_empty_string(state_name) do
      nil -> {:error, :invalid_state_name}
      normalized_state_name -> {:ok, normalized_state_name}
    end
  end

  defp maybe_put_continuation_token(query, nil), do: query

  defp maybe_put_continuation_token(query, continuation_token) when is_binary(continuation_token) do
    Map.put(query, "continuationToken", continuation_token)
  end

  defp next_comments_continuation_token(%{"continuationToken" => continuation_token}) do
    normalize_non_empty_string(continuation_token)
  end

  defp next_comments_continuation_token(_body), do: nil

  defp normalize_non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_non_empty_string(_value), do: nil

  defp azure_devops_error_context(path, response) do
    " path=" <> inspect(path) <> " body=" <> summarize_error_body(Map.get(response, :body))
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
