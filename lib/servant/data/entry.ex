defmodule Servant.Data.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "entries" do
    field :kind, :string
    field :source, :string
    field :external_id, :string
    field :title, :string
    field :occurred_at, :utc_datetime
    field :data, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :source, :external_id, :title, :occurred_at, :data, :metadata])
    |> validate_required([:kind, :source])
    |> unique_constraint([:user_id, :source, :external_id])
  end

  @doc """
  Canonical JSON-serializable map for an entry. Single source of truth shared by
  the entry/export controllers and the data channel.
  """
  def to_json(%__MODULE__{} = entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      source: entry.source,
      external_id: entry.external_id,
      title: entry.title,
      occurred_at: entry.occurred_at,
      data: entry.data,
      metadata: entry.metadata,
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end
end
