defmodule Servant.Connectors.SyncLog do
  @moduledoc """
  One row per connector sync run (or file import): status, counts, error.
  `entries_count` is the new entries, `fetched_count` all the entries the
  connector returned. `details` holds what the run did (see
  `Servant.Connectors.SyncTrace`); only the most recent runs keep it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sync_logs" do
    field :status, :string
    field :entries_count, :integer, default: 0
    field :fetched_count, :integer, default: 0
    field :http_count, :integer, default: 0
    field :http_failed_count, :integer, default: 0
    field :log_count, :integer, default: 0
    field :details, :map
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :connector_config, Servant.Connectors.ConnectorConfig

    timestamps(type: :utc_datetime)
  end

  def changeset(sync_log, attrs) do
    sync_log
    |> cast(attrs, [
      :connector_config_id,
      :status,
      :entries_count,
      :fetched_count,
      :http_count,
      :http_failed_count,
      :log_count,
      :details,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:connector_config_id, :status, :started_at])
    |> validate_inclusion(:status, ~w(running completed failed))
  end
end
