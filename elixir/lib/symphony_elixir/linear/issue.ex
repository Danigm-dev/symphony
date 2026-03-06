defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Compatibility wrapper for Linear issues while the runtime uses `SymphonyElixir.Issue`.
  """

  alias SymphonyElixir.Issue

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          blocked_by: [Issue.blocker_t()],
          labels: [term()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec from_issue(Issue.t() | map()) :: t()
  def from_issue(issue) do
    issue
    |> Issue.from()
    |> Map.from_struct()
    |> then(&struct(__MODULE__, &1))
  end

  @spec to_issue(t() | map()) :: Issue.t()
  def to_issue(issue), do: Issue.from(issue)

  @spec label_names(t()) :: [term()]
  def label_names(issue), do: issue |> to_issue() |> Issue.label_names()
end
