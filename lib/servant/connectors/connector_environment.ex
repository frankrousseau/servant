defmodule Servant.Connectors.ConnectorEnvironment do
  @moduledoc "Per-connector persisted key/value state."

  use Ecto.Schema
  import Ecto.Changeset

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

  def changeset(env, attrs) do
    env
    |> cast(attrs, [:connector_type, :namespace, :key, :value, :expires_at])
    |> validate_required([:connector_type, :namespace, :key])
  end
end
