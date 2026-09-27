#!/bin/sh
# Read-only EXIF diagnosis of the most recent photo, run against the live
# Docker release (no redeploy needed). Run it from the directory holding
# docker-compose.yml:
#
#   ./scripts/diagnose-photo-exif.sh
#
# Reading the output:
#   has_exif_marker: false         -> the file has no EXIF at all (stripped by
#                                     a HEIC-to-JPEG conversion): nothing to
#                                     recover, fix the upload app instead
#   has_exif_marker: true and
#   extract: %{}                   -> EXIF present but our parser fails
#   extract has a date but
#   date_taken: nil                -> backfill selection issue
#   "path not resolved"            -> storage path issue

exec docker compose exec servant bin/servant rpc '
import Ecto.Query

e =
  Servant.Repo.one(
    from e in Servant.Data.Entry,
      where: e.kind == "photo",
      order_by: [desc: e.inserted_at],
      limit: 1
  )

rel = Servant.Storage.relative_from_public(e.data["path"])

case Servant.Storage.resolve_owned_path(e.user_id, rel) do
  {:ok, abs} ->
    bin = File.read!(abs)

    IO.inspect(%{
      filename: e.data["filename"],
      mime: e.data["mime_type"],
      date_taken: e.data["date_taken"],
      has_exif_marker: :binary.match(bin, "Exif") != :nomatch,
      extract: Servant.Media.Exif.extract(abs)
    })

  other ->
    IO.inspect(other, label: "path not resolved")
end'
