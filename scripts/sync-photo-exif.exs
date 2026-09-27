# Restores the date, location and camera of Servant photos from their
# originals on disk. Photos uploaded from an iPhone through the browser were
# converted from HEIC to JPEG without their EXIF: Servant holds IMG_1234.jpg,
# the phone export holds IMG_1234.HEIC with the metadata. Matching goes by
# file name without extension, case-insensitive.
#
#   export SERVANT_URL=https://servant.example.net SERVANT_TOKEN=srv_...
#   mix run --no-start scripts/sync-photo-exif.exs ~/Pictures/iphone-export
#   mix run --no-start scripts/sync-photo-exif.exs ~/Pictures/iphone-export --apply
#
# Dry run by default: it prints what it would change and writes nothing until
# --apply. Only photos without a date and a location are touched, and stored
# values are never overwritten. The token needs app:photos:write (or
# data:write). A name found twice locally (iPhone numbering wraps at 9999) is
# skipped rather than guessed.

alias Servant.Media.Exif

{opts, args} = OptionParser.parse!(System.argv(), strict: [apply: :boolean])

dir =
  case args do
    [dir] -> Path.expand(dir)
    _ -> Mix.raise("usage: mix run --no-start scripts/sync-photo-exif.exs DIR [--apply]")
  end

unless File.dir?(dir), do: Mix.raise("not a directory: #{dir}")

url = System.get_env("SERVANT_URL") || Mix.raise("SERVANT_URL is not set")
token = System.get_env("SERVANT_TOKEN") || Mix.raise("SERVANT_TOKEN is not set")
apply? = Keyword.get(opts, :apply, false)

{:ok, _} = Application.ensure_all_started(:req)
api = Req.new(base_url: String.trim_trailing(url, "/") <> "/api", auth: {:bearer, token})

key = fn name -> name |> Path.rootname() |> String.downcase() end

# ----- local originals, indexed by name -----

local =
  dir
  |> Path.join("**/*")
  |> Path.wildcard(match_dot: false)
  |> Enum.filter(&(String.downcase(Path.extname(&1)) in ~w(.heic .heif .jpg .jpeg)))
  |> Enum.group_by(&key.(Path.basename(&1)))

IO.puts("#{map_size(local)} local originals under #{dir}")

# ----- Servant photos still missing their metadata -----

fetch_page = fn page ->
  Req.get!(api, url: "/entries", params: [kind: "photo", per_page: 1000, page: page]).body
end

first = fetch_page.(1)
pages = for page <- 2..first["meta"]["total_pages"]//1, do: fetch_page.(page)
photos = Enum.flat_map([first | pages], & &1["data"])

missing =
  Enum.filter(photos, fn photo ->
    data = photo["data"] || %{}
    is_nil(data["date_taken"]) and is_nil(data["latitude"]) and is_binary(data["filename"])
  end)

IO.puts("#{length(photos)} photos in Servant, #{length(missing)} without date or location\n")

# ----- match, read, update -----

results =
  for photo <- missing do
    data = photo["data"]

    case Map.get(local, key.(data["filename"])) do
      nil ->
        :no_local

      [_one, _another | _] = paths ->
        IO.puts("skip #{data["filename"]}: found #{length(paths)} times locally")
        :ambiguous

      [path] ->
        case Exif.entry_fields(Exif.extract(path)) do
          fields when map_size(fields) == 0 ->
            IO.puts("skip #{data["filename"]}: no EXIF in #{Path.basename(path)}")
            :no_exif

          fields ->
            IO.puts(
              "#{if apply?, do: "update", else: "would update"} #{data["filename"]} <- " <>
                "#{Path.basename(path)}: #{inspect(fields)}"
            )

            if apply? do
              body = %{data: Map.merge(fields, data)}

              body =
                if fields["date_taken"],
                  do: Map.put(body, :occurred_at, fields["date_taken"]),
                  else: body

              Req.put!(api, url: "/entries/#{photo["id"]}", json: body)
            end

            :updated
        end
    end
  end

counts = Enum.frequencies(results)

IO.puts("""

#{Map.get(counts, :updated, 0)} #{if apply?, do: "updated", else: "to update (rerun with --apply)"}
#{Map.get(counts, :no_local, 0)} without a local original
#{Map.get(counts, :ambiguous, 0)} ambiguous names
#{Map.get(counts, :no_exif, 0)} originals without EXIF
""")
