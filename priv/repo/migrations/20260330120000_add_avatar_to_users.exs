defmodule Servant.Repo.Migrations.AddAvatarAndEmailToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :avatar_path, :string
      add :email, :string
    end
  end
end
