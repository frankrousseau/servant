defmodule Servant.Accounts do
  @moduledoc """
  The Accounts context.
  """

  alias Servant.Accounts.User
  alias Servant.Repo

  def register_user(attrs) do
    changeset = User.registration_changeset(%User{}, attrs)

    # The first account on a new instance is the operator (admin). The code
    # sets the admin flag and never casts it, so mass assignment cannot set it.
    changeset =
      if Repo.aggregate(User, :count) == 0 do
        Ecto.Changeset.put_change(changeset, :admin, true)
      else
        changeset
      end

    Repo.insert(changeset)
  end

  def authenticate_user(username, password) do
    user = Repo.get_by(User, username: username)

    cond do
      user && Bcrypt.verify_pass(password, user.hashed_password) ->
        {:ok, user}

      user ->
        {:error, :invalid_credentials}

      true ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id), do: Repo.get(User, id)

  def update_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @ai_defaults %{
    "enabled" => false,
    "base_url" => "http://localhost:11434/v1",
    "model" => "",
    "api_key" => nil
  }

  @doc "Returns the AI agents config, with the defaults for the missing keys (string keys)."
  def ai_config(%User{} = user), do: Map.merge(@ai_defaults, user.ai_config || %{})

  def ai_enabled?(%User{} = user), do: ai_config(user)["enabled"] == true

  @doc "Returns ai_config with \"***\" in the place of the API key (for API responses)."
  def masked_ai_config(%User{} = user) do
    config = ai_config(user)
    %{config | "api_key" => if(config["api_key"], do: "***", else: nil)}
  end

  @doc """
  Updates the AI config from the attrs that the user supplies. The function
  ignores unknown keys. An api_key of "***" keeps the stored key, because
  "***" is the value that the API returns.
  """
  def update_ai_config(%User{} = user, attrs) when is_map(attrs) do
    current = ai_config(user)

    config = %{
      "enabled" => Map.get(attrs, "enabled", current["enabled"]) == true,
      "base_url" =>
        attrs |> Map.get("base_url", current["base_url"]) |> to_string() |> String.trim(),
      "model" => attrs |> Map.get("model", current["model"]) |> to_string() |> String.trim(),
      "api_key" => resolve_api_key(Map.get(attrs, "api_key", :keep), current["api_key"])
    }

    cond do
      not String.starts_with?(config["base_url"], ["http://", "https://"]) ->
        {:error, "base_url must be an http(s) URL"}

      config["enabled"] and config["model"] == "" ->
        {:error, "model is required to enable agents"}

      true ->
        user |> User.ai_config_changeset(config) |> Repo.update()
    end
  end

  defp resolve_api_key(:keep, current), do: current
  defp resolve_api_key("***", current), do: current
  defp resolve_api_key(nil, _current), do: nil

  defp resolve_api_key(key, _current) when is_binary(key) do
    case String.trim(key) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A value that is not a binary (for example api_key: 123 in the PUT JSON)
  # keeps the current key and does not raise a FunctionClauseError.
  defp resolve_api_key(_key, current), do: current

  def update_avatar(user, %Plug.Upload{path: tmp_path, content_type: content_type}) do
    ext =
      case content_type do
        "image/png" -> ".png"
        "image/jpeg" -> ".jpg"
        "image/gif" -> ".gif"
        "image/webp" -> ".webp"
        _ -> ".jpg"
      end

    with {:ok, relative, _absolute} <-
           Servant.Storage.store_account_avatar(user.id, tmp_path, ext) do
      avatar_url = Servant.Storage.public_url(relative)

      user
      |> User.avatar_changeset(avatar_url)
      |> Repo.update()
    end
  end

  def change_password(user, current_password, new_password) do
    if Bcrypt.verify_pass(current_password, user.hashed_password) do
      user
      |> User.password_changeset(%{"password" => new_password})
      # Invalidate the existing sessions. A user rotates the password after a
      # compromise, and a stolen token must not stay valid after that rotation.
      |> Ecto.Changeset.put_change(:token_version, user.token_version + 1)
      |> Repo.update()
    else
      {:error, :wrong_password}
    end
  end

  @doc "Increments the token_version of the user. This invalidates every existing auth token."
  def bump_token_version(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{token_version: user.token_version + 1})
    |> Repo.update()
  end

  # ----- TOTP (two-factor authentication) -----
  # Servant.Encrypted encrypts the stored secret with AES-256-GCM. The last
  # accepted timestamp refuses a replay of a code in the 30s window. On a
  # self-hosted instance, the operator does the recovery: clear
  # users.totp_secret in the database.

  @doc "Returns true if two-factor authentication is enabled for the user."
  def totp_enabled?(%User{totp_secret: secret}), do: is_binary(secret)

  @doc """
  Enables TOTP after the user proves that they scanned the secret. A new valid
  code is necessary.
  """
  def enable_totp(%User{} = user, secret, code)
      when is_binary(secret) and is_binary(code) do
    if NimbleTOTP.valid?(secret, code) do
      user
      |> Ecto.Changeset.change(%{
        totp_secret: Servant.Encrypted.encrypt(secret),
        totp_last_used_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
      |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  @doc "Disables TOTP. A code that is valid at this time is necessary."
  def disable_totp(%User{} = user, code) do
    case verify_totp(user, code) do
      {:ok, user} ->
        user
        |> Ecto.Changeset.change(%{
          totp_secret: nil,
          totp_last_used_at: nil,
          # The removal of the second factor also invalidates the existing sessions.
          token_version: user.token_version + 1
        })
        |> Repo.update()

      :error ->
        {:error, :invalid_code}
    end
  end

  @doc """
  Compares a login code with the stored secret. Accepts each code one time
  only: `since:` refuses a code at or before the last accepted timestamp. On
  success, updates that timestamp.
  """
  def verify_totp(%User{totp_secret: encrypted} = user, code)
      when is_binary(encrypted) and is_binary(code) do
    with {:ok, secret} <- Servant.Encrypted.decrypt(encrypted),
         true <- NimbleTOTP.valid?(secret, code, since: user.totp_last_used_at) do
      user
      |> Ecto.Changeset.change(%{
        totp_last_used_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
      |> Repo.update()
    else
      _ -> :error
    end
  end

  def verify_totp(_user, _code), do: :error
end
