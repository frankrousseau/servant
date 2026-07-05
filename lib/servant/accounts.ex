defmodule Servant.Accounts do
  @moduledoc """
  The Accounts context.
  """

  alias Servant.Accounts.User
  alias Servant.Repo

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
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
      |> Repo.update()
    else
      {:error, :wrong_password}
    end
  end
end
