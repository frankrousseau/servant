defmodule Servant.ApiTokens do
  @moduledoc """
  Scoped API tokens for agents and scripts. The plaintext (`srv_` prefixed) is
  returned exactly once at creation; only its SHA-256 hash lands in the
  database. Tokens are individually revocable and independent of the session
  `token_version` (revoking an agent does not log the user out).
  """

  import Ecto.Query

  alias Servant.Accounts
  alias Servant.ApiTokens.ApiToken
  alias Servant.Repo

  @prefix "srv_"
  # last_used_at is refreshed at most once per interval, not on every request
  @touch_interval_s 60

  def list_tokens(user_id) do
    ApiToken
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc "Creates a token. Returns `{:ok, struct, plaintext}`; the plaintext is shown once."
  def create_token(user_id, attrs) do
    plaintext = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    changeset =
      %ApiToken{}
      |> ApiToken.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user_id)
      |> Ecto.Changeset.put_change(:token_hash, hash(plaintext))
      |> Ecto.Changeset.put_change(:prefix, String.slice(plaintext, 0, 8))

    case Repo.insert(changeset) do
      {:ok, api_token} -> {:ok, api_token, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete_token(user_id, id) do
    case Repo.get_by(ApiToken, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  @doc """
  Authenticates a plaintext API token: `{:ok, user, scopes}` when the hash is
  known, the token is not expired and the user still exists.
  """
  def authenticate(@prefix <> _ = plaintext) do
    with %ApiToken{} = token <- Repo.get_by(ApiToken, token_hash: hash(plaintext)),
         false <- expired?(token),
         user when not is_nil(user) <- Accounts.get_user(token.user_id) do
      touch(token)
      {:ok, user, token.scopes}
    else
      _ -> :error
    end
  end

  def authenticate(_), do: :error

  defp expired?(%ApiToken{expires_at: nil}), do: false
  defp expired?(%ApiToken{expires_at: at}), do: DateTime.compare(at, DateTime.utc_now()) == :lt

  defp touch(%ApiToken{} = token) do
    now = DateTime.utc_now(:second)
    stale = DateTime.add(now, -@touch_interval_s, :second)

    if is_nil(token.last_used_at) or DateTime.compare(token.last_used_at, stale) == :lt do
      ApiToken
      |> where(id: ^token.id)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  defp hash(plaintext) do
    Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower)
  end
end
