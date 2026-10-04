defmodule Servant.Accounts.User do
  @moduledoc "User schema: credentials, profile, timezone and display preferences."

  @themes ~w(night graphite day cyanotype sepia rosewood)
  # For each of the two formats, nil means "render like the browser does".
  @time_formats ~w(24h 12h)
  @date_formats ~w(dmy mdy iso)
  @max_preferences_bytes 65_536

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
    field :theme, :string, default: "night"
    field :time_format, :string
    field :date_format, :string
    # nil means "the default set" (DEFAULT_ENABLED_APPS in the frontend
    # registry). The ids are opaque here. The frontend owns the list of apps.
    field :enabled_apps, {:array, :string}
    # The UI preferences of each app, with "<app>.<name>" keys. They are opaque
    # to the server.
    field :preferences, :map, default: %{}
    # The config of the AI agents (enabled/base_url/model/api_key). It is
    # encrypted at rest, like the connector secrets.
    field :ai_config, Servant.Encrypted.Map, redact: true
    field :totp_secret, :binary, redact: true
    field :totp_last_used_at, :utc_datetime
    field :token_version, :integer, default: 0
    field :admin, :boolean, default: false
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
    |> cast(attrs, [
      :display_name,
      :email,
      :timezone,
      :theme,
      :enabled_apps,
      :time_format,
      :date_format
    ])
    |> validate_length(:display_name, max: 100)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_inclusion(:theme, @themes)
    |> validate_inclusion(:time_format, @time_formats)
    |> validate_inclusion(:date_format, @date_formats)
    |> validate_enabled_apps()
    |> validate_timezone()
    |> merge_preferences(attrs)
  end

  # The server patches the preferences, it does not replace them. Each app sends
  # only its own keys. As a result, two apps that save at the same time never
  # erase the keys of each other. A nil value drops the key.
  # ponytail: the merge uses the user loaded for this request. As a result, two
  # saves at the same instant can still lose one key. If that occurs, move the
  # merge into SQL (json_patch).

  defp merge_preferences(changeset, %{"preferences" => prefs}) when is_map(prefs) do
    merged =
      (changeset.data.preferences || %{})
      |> Map.merge(prefs)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if byte_size(Jason.encode!(merged)) > @max_preferences_bytes do
      add_error(changeset, :preferences, "are too large")
    else
      put_change(changeset, :preferences, merged)
    end
  end

  defp merge_preferences(changeset, %{"preferences" => _prefs}),
    do: add_error(changeset, :preferences, "must be an object")

  defp merge_preferences(changeset, _attrs), do: changeset

  # The app ids are slugs that the frontend registry owns. This function
  # validates only their shape. As a result, an old backend never rejects the
  # apps of a newer frontend.
  defp validate_enabled_apps(changeset) do
    changeset
    |> validate_length(:enabled_apps, max: 100)
    |> validate_change(:enabled_apps, fn :enabled_apps, ids ->
      if Enum.all?(ids, &(is_binary(&1) and &1 =~ ~r/^[a-z0-9_-]{1,50}$/)) do
        []
      else
        [enabled_apps: "must be a list of app ids"]
      end
    end)
  end

  # The IANA tz database is in the browser, which uses it for display. As a
  # result, the server does only a sanity check of the string: a bare IANA-style
  # name such as "Europe/Paris" or "UTC". This keeps out junk and adds no tz
  # dependency.
  defp validate_timezone(changeset) do
    changeset
    |> validate_length(:timezone, max: 64)
    |> validate_format(:timezone, ~r{^[A-Za-z0-9+._/-]+$}, message: "must be a valid timezone")
  end

  def avatar_changeset(user, avatar_path) do
    user
    |> change(%{avatar_path: avatar_path})
  end

  def ai_config_changeset(user, config) when is_map(config) do
    change(user, ai_config: config)
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
