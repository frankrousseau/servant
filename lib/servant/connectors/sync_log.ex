defmodule Servant.Connectors.SyncLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sync_logs" do
    field :status, :string
    field :entries_count, :integer, default: 0
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :connector_config, Servant.Connectors.ConnectorConfig

    timestamps(type: :utc_datetime)
  end

  def changeset(sync_log, attrs) do
    sync_log
    |> cast(attrs, [:connector_config_id, :status, :entries_count, :error, :started_at, :finished_at])
    |> validate_required([:connector_config_id, :status, :started_at])
    |> validate_inclusion(:status, ~w(running completed failed))
  end
end
