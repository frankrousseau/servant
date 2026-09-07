defmodule Servant.Connectors.ConnectorEnvironment do
  @moduledoc "Per-connector persisted key/value state."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "connector_environment" do
    field :connector_type, :string
    field :namespace, :string
    field :key, :string
    field :value, :map, default: %{}
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
