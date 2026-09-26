defmodule Servant.Repo.Migrations.AddPeopleToPhotoShares do
  use Ecto.Migration

  # People (contacts) a share selects on, beside its tags: [{id, name}], the
  # same snapshot shape as a photo's data.people.
  def change do
    alter table(:photo_shares) do
      add :people, {:array, :map}, null: false, default: []
    end
  end
end
