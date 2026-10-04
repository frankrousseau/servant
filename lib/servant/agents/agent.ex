defmodule Servant.Agents.Agent do
  @moduledoc """
  A recurring agent that runs on a schedule over a selection of the user's
  entries. There are two modes. In "prompt" mode, the model writes an
  ai_report entry. In "recipe" mode, a deterministic interpreter runs a
  declarative recipe and makes a report entry with no model call.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Servant.Agents.Recipe

  @schedules ~w(every_hour every_day every_week)
  @modes ~w(prompt recipe)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :name, :string
    field :prompt, :string
    field :mode, :string, default: "prompt"
    field :recipe, :map
    # If the value is null, the agent uses the model configured in Settings > Agents.
    field :model, :string
    field :kinds, {:array, :string}
    field :lookback_days, :integer, default: 7
    field :schedule, :string, default: "every_day"
    # The hour of the day (in the user's timezone) at which a daily or weekly
    # agent fires. If the value is null, the agent keeps the interval counted
    # from the previous run.
    field :run_at_hour, :integer
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :prompt,
      :mode,
      :recipe,
      :model,
      :kinds,
      :lookback_days,
      :schedule,
      :run_at_hour,
      :enabled
    ])
    |> validate_required([:name, :kinds])
    |> validate_inclusion(:mode, @modes)
    |> validate_length(:name, max: 60)
    |> validate_length(:prompt, max: 4000)
    |> update_change(:model, &blank_to_nil/1)
    |> validate_length(:model, max: 120)
    |> update_change(:kinds, &Enum.uniq/1)
    |> validate_kinds()
    |> validate_number(:lookback_days, greater_than: 0, less_than_or_equal_to: 365)
    |> validate_inclusion(:schedule, @schedules)
    |> validate_number(:run_at_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_by_mode()
  end

  # A prompt agent must have a prompt. A recipe agent must have a valid recipe.
  # A mode switch clears the field that the new mode does not use. As a result,
  # a stored but inactive value can never come back when the mode switches back.
  defp validate_by_mode(changeset) do
    case get_field(changeset, :mode) do
      "recipe" ->
        changeset
        |> validate_required([:recipe])
        |> validate_recipe()
        |> clear_field_unless_nil(:prompt)

      _mode ->
        changeset
        |> validate_required([:prompt])
        |> clear_field_unless_nil(:recipe)
    end
  end

  # Reads the current recipe (possibly unchanged, possibly changed) directly
  # and does not use validate_change/3. validate_change/3 runs only when
  # :recipe is part of the changes of this changeset. A bare mode switch to
  # "recipe" with no recipe change must still validate the recipe that is
  # already on the record.
  defp validate_recipe(changeset) do
    case get_field(changeset, :recipe) do
      # validate_required/2 above already adds an error for a nil recipe.
      nil ->
        changeset

      recipe ->
        case Recipe.validate(recipe) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, :recipe, message)
        end
    end
  end

  # An emptied model field means "back to the Settings model", not "".
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp clear_field_unless_nil(changeset, field) do
    if get_field(changeset, field) == nil do
      changeset
    else
      put_change(changeset, field, nil)
    end
  end

  def schedules, do: @schedules

  # The kinds are slugs. They follow the same shape rule as users.enabled_apps.
  defp validate_kinds(changeset) do
    changeset
    |> validate_length(:kinds, min: 1, max: 20)
    |> validate_change(:kinds, fn :kinds, kinds ->
      if Enum.all?(kinds, &(is_binary(&1) and &1 =~ ~r/^[a-z0-9_-]{1,50}$/)) do
        []
      else
        [kinds: "must be a list of entry kind slugs"]
      end
    end)
  end
end
