defmodule SymphonyElixir.AzureDevOps.Adapter do
  @moduledoc """
  Azure DevOps-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.AzureDevOps.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().create_comment(issue_id, body),
         comment_id when is_integer(comment_id) or is_binary(comment_id) <- Map.get(response, "commentId") do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, response} <- client_module().update_issue_state(issue_id, state_name),
         normalized_state_name <- String.trim(state_name),
         ^normalized_state_name <- get_in(response, ["fields", "System.State"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :azure_devops_client_module, Client)
  end
end
