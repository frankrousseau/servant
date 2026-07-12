defmodule Servant.Apps.UserApp do
  @moduledoc "An app installed from a git repository, loaded by the SPA like a builtin app."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_apps" do
    field :app_id, :string
    field :name, :string
    field :description, :string
    field :icon, :string
    field :entry, :string
    field :repo_url, :string

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(user_app, attrs) do
    user_app
    |> cast(attrs, [:app_id, :name, :description, :icon, :entry, :repo_url])
    |> validate_required([:app_id, :name, :entry, :repo_url])
    |> unique_constraint([:user_id, :app_id])
  end
end
