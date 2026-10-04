defmodule Servant.Release do
  @moduledoc "Release tasks (migrations) that you can run without Mix."
  @app :servant

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def backfill_photo_thumbnails do
    load_app()

    repo = List.first(repos())

    {:ok, results, _} =
      Ecto.Migrator.with_repo(repo, fn _ ->
        Servant.Media.Thumbnail.backfill_missing()
      end)

    Enum.each(results, fn
      {:ok, id} ->
        IO.puts("thumbnail backfill ok: #{id}")

      {:error, id, reason} ->
        IO.puts("thumbnail backfill failed: #{id} (#{inspect(reason)})")
    end)

    ok = Enum.count(results, &match?({:ok, _}, &1))
    {ok, length(results)}
  end

  @doc "Fills the date and the location of the photos that had none at import (iPhone HEIC)."
  def backfill_photo_exif do
    load_app()

    {:ok, {updated, scanned}, _} =
      Ecto.Migrator.with_repo(List.first(repos()), fn _ ->
        Servant.Media.Exif.backfill_missing()
      end)

    IO.puts("exif backfill: #{updated} of #{scanned} photos updated")
    {updated, scanned}
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
