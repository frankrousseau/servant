defmodule Servant.Accounts.User do
  @moduledoc "User schema: credentials, profile and timezone preference."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :username, :string
    field :hashed_password, :string
    field :display_name, :string
    field :email, :string
    field :avatar_path, :string
    field :timezone, :string, default: "UTC"
    field :totp_secret, :binary, redact: true
    field :totp_last_used_at, :utc_datetime
    field :token_version, :integer, default: 0
    field :password, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :display_name])
    |> validate_required([:username, :password])
    |> validate_length(:username, min: 3, max: 50)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username)
    |> hash_password()
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :email, :timezone])
    |> validate_length(:display_name, max: 100)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_timezone()
  end

  # The IANA tz database lives in the browser (used for display), so the server
  # only sanity-checks the string: a bare IANA-style name like "Europe/Paris" or
  # "UTC". Keeps out junk without pulling in a tz dependency.
  defp validate_timezone(changeset) do
    changeset
    |> validate_length(:timezone, max: 64)
    |> validate_format(:timezone, ~r{^[A-Za-z0-9+._/-]+$}, message: "must be a valid timezone")
  end

  def avatar_changeset(user, avatar_path) do
    user
    |> change(%{avatar_path: avatar_path})
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
