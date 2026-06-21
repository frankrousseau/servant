defmodule Servant.Accounts do
  @moduledoc """
  The Accounts context.
  """

  alias Servant.Repo
  alias Servant.Accounts.User

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

  def update_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @avatars_dir "avatars"

  def update_avatar(user, %Plug.Upload{path: tmp_path, content_type: content_type}) do
    ext =
      case content_type do
        "image/png" -> ".png"
        "image/jpeg" -> ".jpg"
        "image/gif" -> ".gif"
        "image/webp" -> ".webp"
        _ -> ".jpg"
      end

    filename = "#{user.id}#{ext}"

    dest_dir = Servant.Uploads.join([@avatars_dir])

    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, filename)
    File.cp!(tmp_path, dest_path)

    avatar_url = "/uploads/#{@avatars_dir}/#{filename}"

    user
    |> User.avatar_changeset(avatar_url)
    |> Repo.update()
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
