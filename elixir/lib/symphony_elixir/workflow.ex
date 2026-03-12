defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"
  @workflow_section_order ~w(tracker polling workspace agent codex hooks observability server)
  @tracker_section_order ~w(
    kind
    endpoint
    api_key
    project_slug
    project
    assignee
    active_states
    terminal_states
    wiql
    work_item_types
    area_paths
    iteration_path
    api_version
    repository
    target_branch
    required_reviewers
  )
  @azure_repo_setting_keys ~w(repository target_branch required_reviewers)

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }
  @type azure_repo_settings_input :: %{optional(String.t()) => term()}

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec persist_azure_repo_settings(azure_repo_settings_input()) :: :ok | {:error, term()}
  def persist_azure_repo_settings(attrs) when is_map(attrs) do
    with {:ok, workflow} <- current(),
         :ok <- ensure_azure_devops_tracker(Map.new(workflow)),
         {:ok, normalized_settings} <- normalize_azure_repo_settings(attrs),
         updated_config <- merge_azure_repo_settings(workflow.config, normalized_settings),
         {:ok, updated_content, updated_workflow} <- render_workflow(updated_config, workflow.prompt_template) do
      persist_workflow_content(workflow_file_path(), updated_content, updated_workflow)
    end
  end

  @spec infer_azure_repo_from_origin() :: String.t() | nil
  def infer_azure_repo_from_origin do
    workflow_file_path()
    |> Path.dirname()
    |> git_origin_url()
    |> parse_azure_repo_name_from_remote_url()
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_azure_devops_tracker(workflow) do
    case workflow do
      %{config: config} when is_map(config) ->
        case get_in(config, ["tracker", "kind"]) do
          "azure_devops" -> :ok
          _other -> {:error, :azure_repo_settings_require_azure_devops_tracker}
        end

      _workflow ->
        {:error, :azure_repo_settings_require_azure_devops_tracker}
    end
  end

  defp normalize_azure_repo_settings(attrs) do
    repository = normalize_required_string(Map.get(attrs, "repository"))
    target_branch = normalize_required_string(Map.get(attrs, "target_branch"))
    required_reviewers = normalize_required_reviewers(Map.get(attrs, "required_reviewers"))

    cond do
      is_nil(repository) ->
        {:error, :missing_azure_devops_repository}

      is_nil(target_branch) ->
        {:error, :missing_azure_devops_target_branch}

      true ->
        {:ok,
         %{
           "repository" => repository,
           "target_branch" => target_branch,
           "required_reviewers" => required_reviewers
         }}
    end
  end

  defp merge_azure_repo_settings(config, normalized_settings) when is_map(config) do
    tracker =
      config
      |> Map.get("tracker", %{})
      |> Map.merge(normalized_settings)
      |> Enum.reject(fn {key, value} -> key in @azure_repo_setting_keys and is_nil(value) end)
      |> Map.new()

    Map.put(config, "tracker", tracker)
  end

  defp render_workflow(config, prompt) do
    yaml = config |> yaml_lines() |> Enum.join("\n")
    trimmed_prompt = String.trim(prompt)

    content =
      ["---", yaml, "---", trimmed_prompt]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> String.replace_prefix("---\n---", "")
      |> String.trim_leading("\n")

    with {:ok, workflow} <- parse(content) do
      {:ok, content <> "\n", workflow}
    end
  end

  defp persist_workflow_content(path, content, workflow) do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        case File.write(path, content) do
          :ok -> WorkflowStore.replace_workflow(path, workflow, content)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        with :ok <- File.write(path, content),
             {:ok, _workflow} <- load() do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end

  defp yaml_lines(map) when is_map(map) do
    map
    |> ordered_entries([])
    |> Enum.flat_map(fn {key, value} -> yaml_entry_lines(key, value, 0) end)
  end

  defp yaml_entry_lines(key, value, indent) when is_map(value) do
    rendered_children =
      value
      |> ordered_entries(key)
      |> Enum.flat_map(fn {child_key, child_value} -> yaml_entry_lines(child_key, child_value, indent + 2) end)

    if rendered_children == [] do
      [indent(indent) <> "#{key}: {}"]
    else
      [indent(indent) <> "#{key}:" | rendered_children]
    end
  end

  defp yaml_entry_lines(key, value, indent) when is_list(value) do
    rendered_items = yaml_list_lines(value, indent + 2)

    if rendered_items == [] do
      [indent(indent) <> "#{key}: []"]
    else
      [indent(indent) <> "#{key}:" | rendered_items]
    end
  end

  defp yaml_entry_lines(key, value, indent) do
    [indent(indent) <> "#{key}: #{yaml_scalar(value)}"]
  end

  defp yaml_list_lines(values, indent) do
    Enum.flat_map(values, fn
      value when is_map(value) ->
        [indent(indent) <> "-"] ++
          (value
           |> ordered_entries([])
           |> Enum.flat_map(fn {child_key, child_value} -> yaml_entry_lines(child_key, child_value, indent + 2) end))

      value when is_list(value) ->
        [indent(indent) <> "-"] ++ yaml_list_lines(value, indent + 2)

      value ->
        [indent(indent) <> "- " <> yaml_scalar(value)]
    end)
  end

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_float(value), do: Float.to_string(value)

  defp yaml_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp yaml_scalar(value) when is_atom(value), do: value |> Atom.to_string() |> yaml_scalar()

  defp ordered_entries(map, parent_key) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> {key_rank(parent_key, key), key} end)
  end

  defp key_rank([], key), do: preferred_key_index(@workflow_section_order, key)
  defp key_rank("tracker", key), do: preferred_key_index(@tracker_section_order, key)
  defp key_rank(_parent_key, key), do: preferred_key_index([], key)

  defp preferred_key_index(keys, key) do
    case Enum.find_index(keys, &(&1 == key)) do
      nil -> length(keys) + 1
      index -> index
    end
  end

  defp indent(size), do: String.duplicate(" ", size)

  defp normalize_required_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_required_string(_value), do: nil

  defp normalize_required_reviewers(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      reviewers -> reviewers
    end
  end

  defp normalize_required_reviewers(values) when is_list(values) do
    values
    |> Enum.map(&normalize_required_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      reviewers -> reviewers
    end
  end

  defp normalize_required_reviewers(_value), do: nil

  defp git_origin_url(dir) when is_binary(dir) do
    with git when not is_nil(git) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(git, ["config", "--get", "remote.origin.url"], cd: dir, stderr_to_stdout: true) do
      blank_to_nil(output)
    else
      _ -> nil
    end
  end

  defp parse_azure_repo_name_from_remote_url(remote_url) when is_binary(remote_url) do
    if String.contains?(remote_url, ["dev.azure.com", "ssh.dev.azure.com"]) do
      remote_url
      |> String.trim_trailing("/")
      |> String.split("/", trim: true)
      |> List.last()
      |> Kernel.||("")
      |> String.trim_trailing(".git")
      |> blank_to_nil()
    else
      nil
    end
  end

  defp parse_azure_repo_name_from_remote_url(_remote_url), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
