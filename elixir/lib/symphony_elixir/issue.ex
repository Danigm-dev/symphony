defmodule SymphonyElixir.Issue do
  @moduledoc """
  Provider-neutral issue representation used by the runtime.
  """

  @fields [
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
  @field_names Enum.map(@fields, fn
                 {field_name, _default} -> field_name
                 field_name -> field_name
               end)

  defstruct @fields

  @type blocker_t :: %{optional(atom() | String.t()) => term()}

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
          blocked_by: [blocker_t()],
          labels: [term()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec from(term()) :: t()
  def from(%{__struct__: __MODULE__} = issue), do: issue

  def from(%{__struct__: SymphonyElixir.Linear.Issue} = issue) do
    issue
    |> Map.from_struct()
    |> from()
  end

  def from(%{} = issue) do
    issue
    |> known_fields()
    |> then(&struct(__MODULE__, &1))
  end

  def from(_issue), do: %__MODULE__{}

  @spec label_names(t()) :: [term()]
  def label_names(%__MODULE__{labels: labels}) when is_list(labels), do: labels
  def label_names(%__MODULE__{}), do: []

  defp known_fields(issue) when is_map(issue) do
    Enum.reduce(@field_names, %{}, fn field_name, acc ->
      cond do
        Map.has_key?(issue, field_name) ->
          Map.put(acc, field_name, Map.get(issue, field_name))

        Map.has_key?(issue, Atom.to_string(field_name)) ->
          Map.put(acc, field_name, Map.get(issue, Atom.to_string(field_name)))

        true ->
          acc
      end
    end)
  end
end
