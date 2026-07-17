defmodule Servant.Accounts do
  @moduledoc """
  The Accounts context.
  """

  alias Servant.Accounts.User
  alias Servant.Repo

  def register_user(attrs) do
    changeset = User.registration_changeset(%User{}, attrs)

    # The first account created on a fresh instance is the operator (admin).
    # Set programmatically, never cast, so it can't be mass-assigned.
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

  @doc "AI agents config with defaults merged in (string keys)."
  def ai_config(%User{} = user), do: Map.merge(@ai_defaults, user.ai_config || %{})

  def ai_enabled?(%User{} = user), do: ai_config(user)["enabled"] == true

  @doc "ai_config with the API key replaced by \"***\" (for API responses)."
  def masked_ai_config(%User{} = user) do
    config = ai_config(user)
    %{config | "api_key" => if(config["api_key"], do: "***", else: nil)}
  end

  @doc """
  Updates the AI config from user-supplied attrs. Unknown keys are ignored;
  an api_key of "***" keeps the stored one (that is what the API returns).
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

  # Non-binary garbage (e.g. api_key: 123 in the PUT JSON) keeps the current
  # key instead of raising a FunctionClauseError.
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
      # Invalidate existing sessions: a stolen token must not survive the very
      # rotation a user reaches for after a compromise.
      |> Ecto.Changeset.put_change(:token_version, user.token_version + 1)
      |> Repo.update()
    else
      {:error, :wrong_password}
    end
  end

  @doc "Bumps the user's token_version, invalidating every existing auth token."
  def bump_token_version(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{token_version: user.token_version + 1})
    |> Repo.update()
  end

  # ----- TOTP (two-factor authentication) -----
  # The secret is stored AES-256-GCM encrypted (Servant.Encrypted); the last
  # accepted timestamp refuses code replays within the 30s window. Recovery
  # is operator-side on a self-hosted instance: clear users.totp_secret in
  # the database.

  @doc "Whether the user has two-factor authentication enabled."
  def totp_enabled?(%User{totp_secret: secret}), do: is_binary(secret)

  @doc """
  Enables TOTP once the user proved they scanned the secret (a fresh valid
  code is required).
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

  @doc "Disables TOTP; requires a currently valid code."
  def disable_totp(%User{} = user, code) do
    case verify_totp(user, code) do
      {:ok, user} ->
        user
        |> Ecto.Changeset.change(%{
          totp_secret: nil,
          totp_last_used_at: nil,
          # Removing the second factor invalidates existing sessions too.
          token_version: user.token_version + 1
        })
        |> Repo.update()

      :error ->
        {:error, :invalid_code}
    end
  end

  @doc """
  Verifies a login code against the stored secret. Accepts each code once
  (`since:` refuses anything at or before the last accepted timestamp) and
  bumps that timestamp on success.
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
