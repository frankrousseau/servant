defmodule Servant.ApiTokens.ApiToken do
  @moduledoc "A scoped, individually revocable API token. Only the SHA-256 hash is stored."

  use Ecto.Schema

  import Ecto.Changeset

  alias Servant.ApiTokens.Scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :prefix, :string
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  # user_id, token_hash and prefix are set programmatically by the context,
  # never cast from params.
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :scopes, :expires_at])
    |> validate_required([:name, :scopes])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_scopes()
  end

  defp validate_scopes(changeset) do
    changeset
    |> validate_length(:scopes, min: 1)
    |> validate_change(:scopes, fn :scopes, scopes ->
      case Enum.reject(scopes, &Scopes.valid?/1) do
        [] -> []
        bad -> [scopes: "unknown scopes: #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  @doc "JSON shape for the management API. Never includes the hash."
  def to_json(%__MODULE__{} = t) do
    %{
      id: t.id,
      name: t.name,
      prefix: t.prefix,
      scopes: t.scopes,
      expires_at: t.expires_at,
      last_used_at: t.last_used_at,
      inserted_at: t.inserted_at
    }
  end
end
