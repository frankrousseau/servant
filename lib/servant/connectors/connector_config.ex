defmodule Servant.Connectors.ConnectorConfig do
  @moduledoc "A connector configuration of a user. The secrets are encrypted at rest."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @all_schedules ~w(on_demand every_5_minutes every_hour every_day every_week continuous)

  schema "connector_configs" do
    field :connector_type, :string
    field :name, :string
    field :enabled, :boolean, default: false
    field :config, Servant.Encrypted.Map, default: %{}
    field :schedule, :string, default: "every_hour"
    field :last_synced_at, :utc_datetime
    field :error, :string

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(connector_config, attrs) do
    connector_config
    |> cast(attrs, [:connector_type, :name, :enabled, :config, :schedule, :last_synced_at, :error])
    |> validate_required([:connector_type])
    |> validate_inclusion(:connector_type, Map.keys(Servant.Connectors.connector_modules()))
    |> validate_inclusion(:schedule, @all_schedules)
  end

  def all_schedules, do: @all_schedules

  def schedule_interval_ms("every_5_minutes"), do: :timer.minutes(5)
  def schedule_interval_ms("every_hour"), do: :timer.hours(1)
  def schedule_interval_ms("every_day"), do: :timer.hours(24)
  def schedule_interval_ms("every_week"), do: :timer.hours(168)
  def schedule_interval_ms("continuous"), do: 0
  def schedule_interval_ms("on_demand"), do: nil
  def schedule_interval_ms(_), do: :timer.hours(1)
end
