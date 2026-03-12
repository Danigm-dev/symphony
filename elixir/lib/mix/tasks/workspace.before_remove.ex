defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  alias SymphonyElixir.{AzureDevOps.Client, Config}

  @shortdoc "Close provider-specific PRs for the current branch before workspace removal"

  @moduledoc """
  Closes open provider-specific pull requests for the current Git branch.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --provider github --repo openai/symphony
      mix workspace.before_remove --provider azure_devops --repo Symphony
      mix workspace.before_remove --repo openai/symphony
  """

  @default_github_repo "openai/symphony"
  @github_provider "github"
  @azure_provider "azure_devops"
  @active_pull_request_status "active"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, provider: :string, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        branch = opts[:branch] || current_branch()
        provider = opts[:provider] |> normalize_provider() || default_provider()
        repo = opts[:repo] || default_repo(provider)

        maybe_close_open_pull_requests(provider, repo, branch)
    end
  end

  @doc false
  @spec normalize_provider_for_test(String.t() | nil) :: String.t() | nil
  def normalize_provider_for_test(provider), do: normalize_provider(provider)

  @doc false
  @spec default_provider_for_test() :: String.t()
  def default_provider_for_test, do: default_provider()

  @doc false
  @spec azure_available_for_test(term()) :: boolean()
  def azure_available_for_test(repo), do: azure_available?(repo)

  @doc false
  @spec parse_repo_name_from_remote_url_for_test(term()) :: String.t() | nil
  def parse_repo_name_from_remote_url_for_test(remote_url), do: parse_repo_name_from_remote_url(remote_url)

  @doc false
  @spec normalize_azure_source_ref_for_test(String.t()) :: String.t()
  def normalize_azure_source_ref_for_test(branch), do: normalize_azure_source_ref(branch)

  @doc false
  @spec normalize_identifier_for_test(term()) :: String.t() | nil
  def normalize_identifier_for_test(value), do: normalize_identifier(value)

  @doc false
  @spec encode_path_segment_for_test(term()) :: String.t()
  def encode_path_segment_for_test(value), do: encode_path_segment(value)

  @doc false
  @spec blank_to_nil_for_test(term()) :: String.t() | nil
  def blank_to_nil_for_test(value), do: blank_to_nil(value)

  defp maybe_close_open_pull_requests(_provider, _repo, nil), do: :ok

  defp maybe_close_open_pull_requests(@azure_provider, repo, branch) do
    if azure_available?(repo) do
      repo
      |> list_open_azure_pull_request_numbers(branch)
      |> Enum.each(&close_azure_pull_request(repo, branch, &1))
    end

    :ok
  end

  defp maybe_close_open_pull_requests(_provider, repo, branch) do
    if gh_available?() and gh_authenticated?() do
      repo
      |> list_open_pull_request_numbers(branch)
      |> Enum.each(&close_pull_request(repo, branch, &1))
    end

    :ok
  end

  defp default_provider do
    case Config.tracker_kind() do
      @azure_provider -> @azure_provider
      _other -> @github_provider
    end
  rescue
    _error -> @github_provider
  end

  defp normalize_provider(nil), do: nil

  defp normalize_provider(provider) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() do
      "" -> nil
      "azure" -> @azure_provider
      @azure_provider -> @azure_provider
      @github_provider -> @github_provider
      other -> Mix.raise("Unsupported provider: #{other}")
    end
  end

  defp default_repo(@azure_provider), do: current_repo_name()
  defp default_repo(_provider), do: @default_github_repo

  defp azure_available?(repo) when is_binary(repo) do
    repo != "" and
      is_binary(Config.azure_devops_endpoint()) and
      is_binary(Config.azure_devops_project()) and
      is_binary(Config.azure_devops_api_token())
  end

  defp azure_available?(_repo), do: false

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp gh_authenticated? do
    match?({:ok, _output}, run_command("gh", ["auth", "status"]))
  end

  defp list_open_pull_request_numbers(repo, branch) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp list_open_azure_pull_request_numbers(repo, branch) do
    case azure_request(:get, azure_pull_requests_path(), %{
           query: %{
             "searchCriteria.repositoryId" => repo,
             "searchCriteria.sourceRefName" => normalize_azure_source_ref(branch),
             "searchCriteria.status" => @active_pull_request_status
           }
         }) do
      {:ok, %{"value" => pull_requests}} when is_list(pull_requests) ->
        pull_requests
        |> Enum.map(&Map.get(&1, "pullRequestId"))
        |> Enum.map(&normalize_identifier/1)
        |> Enum.reject(&is_nil/1)

      {:ok, _unexpected_payload} ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp close_pull_request(repo, branch, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           github_closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp close_azure_pull_request(repo, branch, pr_number) do
    with {:ok, _thread} <- create_azure_closing_thread(repo, branch, pr_number),
         {:ok, _pull_request} <- abandon_azure_pull_request(repo, pr_number) do
      Mix.shell().info("Abandoned Azure PR ##{pr_number} for branch #{branch}")
    else
      {:error, reason} ->
        Mix.shell().error("Failed to abandon Azure PR ##{pr_number} for branch #{branch}: #{inspect(reason)}")
    end
  end

  defp create_azure_closing_thread(repo, branch, pr_number) do
    azure_request(:post, azure_pull_request_threads_path(repo, pr_number), %{
      body: %{
        "comments" => [
          %{
            "parentCommentId" => 0,
            "content" => azure_closing_comment(branch),
            "commentType" => 1
          }
        ],
        "status" => 1
      }
    })
  end

  defp abandon_azure_pull_request(repo, pr_number) do
    azure_request(:patch, azure_pull_request_path(repo, pr_number), %{
      body: %{"status" => "abandoned"}
    })
  end

  defp github_closing_comment(branch) do
    "Closing because the Linear issue for branch #{branch} entered a terminal state without merge."
  end

  defp azure_closing_comment(branch) do
    "Closing because the tracked issue for branch #{branch} entered a terminal state without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp current_branch do
    case run_command("git", ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp current_repo_name do
    case run_command("git", ["config", "--get", "remote.origin.url"]) do
      {:ok, output} ->
        output
        |> String.trim()
        |> parse_repo_name_from_remote_url()

      {:error, _reason} ->
        nil
    end
  end

  defp parse_repo_name_from_remote_url(""), do: nil

  defp parse_repo_name_from_remote_url(remote_url) when is_binary(remote_url) do
    remote_url
    |> String.trim_trailing("/")
    |> String.split("/", trim: true)
    |> List.last()
    |> case do
      nil -> nil
      repo_name -> repo_name |> String.trim_trailing(".git") |> blank_to_nil()
    end
  end

  defp parse_repo_name_from_remote_url(_remote_url), do: nil

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end

  defp azure_request(method, path, request_opts) do
    azure_client_module().raw_request(method, path, request_opts)
  end

  defp azure_client_module do
    Application.get_env(:symphony_elixir, :workspace_before_remove_azure_client_module, Client)
  end

  defp azure_pull_requests_path do
    "/" <> encode_path_segment(Config.azure_devops_project()) <> "/_apis/git/pullrequests"
  end

  defp azure_pull_request_path(repo, pr_number) do
    "/" <>
      encode_path_segment(Config.azure_devops_project()) <>
      "/_apis/git/repositories/" <>
      encode_path_segment(repo) <>
      "/pullRequests/" <> encode_path_segment(pr_number)
  end

  defp azure_pull_request_threads_path(repo, pr_number) do
    azure_pull_request_path(repo, pr_number) <> "/threads"
  end

  defp normalize_azure_source_ref(branch) when is_binary(branch) do
    trimmed_branch = String.trim(branch)

    if String.starts_with?(trimmed_branch, "refs/heads/") do
      trimmed_branch
    else
      "refs/heads/" <> trimmed_branch
    end
  end

  defp normalize_identifier(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_identifier(_value), do: nil

  defp encode_path_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp encode_path_segment(_value), do: ""

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed_value -> trimmed_value
    end
  end

  defp blank_to_nil(_value), do: nil
end
