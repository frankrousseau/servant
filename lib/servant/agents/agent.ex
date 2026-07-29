defmodule Servant.Agents.Agent do
  @moduledoc """
  A recurring agent run on a schedule over a selection of the user's
  entries. Two modes: "prompt" (the model writes an ai_report entry) and
  "recipe" (a declarative recipe interpreted deterministically, producing
  a report entry with no model call).
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
    # Null falls back to the model configured in Settings > Agents.
    field :model, :string
    field :kinds, {:array, :string}
    field :lookback_days, :integer, default: 7
    field :schedule, :string, default: "every_day"
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
    |> validate_by_mode()
  end

  # Prompt agents need a prompt; recipe agents need a valid recipe. Switching
  # mode clears the field the new mode doesn't use, so a stored-but-inactive
  # value can never resurface just by flipping mode back.
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

  # Reads the current (possibly unchanged, possibly changed) recipe directly
  # instead of validate_change/3, which only runs when :recipe is part of
  # this changeset's changes: a bare mode switch to "recipe" with no recipe
  # change must still validate whatever recipe is already on the record.
  defp validate_recipe(changeset) do
    case get_field(changeset, :recipe) do
      # validate_required/2 above already errors on a nil recipe.
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

  # Kind slugs, same shape rule as users.enabled_apps.
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
