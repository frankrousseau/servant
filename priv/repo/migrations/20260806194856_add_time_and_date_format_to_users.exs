defmodule Servant.Repo.Migrations.AddTimeAndDateFormatToUsers do
  use Ecto.Migration

  # Both nullable on purpose: NULL means "render like the browser does", which
  # is what every existing user gets and what the app did before.
  def change do
    alter table(:users) do
      add :time_format, :string
      add :date_format, :string
    end
  end
end
