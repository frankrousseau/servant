defmodule Servant.Agents.Agent do
  @moduledoc """
  A recurring agent: a prompt run on a schedule over a selection of the
  user's entries, producing report entries (kind "ai_report").
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schedules ~w(every_hour every_day every_week)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :name, :string
    field :prompt, :string
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
    |> cast(attrs, [:name, :prompt, :kinds, :lookback_days, :schedule, :enabled])
    |> validate_required([:name, :prompt, :kinds])
    |> validate_length(:name, max: 60)
    |> validate_length(:prompt, max: 4000)
    |> update_change(:kinds, &Enum.uniq/1)
    |> validate_kinds()
    |> validate_number(:lookback_days, greater_than: 0, less_than_or_equal_to: 365)
    |> validate_inclusion(:schedule, @schedules)
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
