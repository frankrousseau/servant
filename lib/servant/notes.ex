defmodule Servant.Notes do
  @moduledoc """
  The Notes context. A note is a `Servant.Data.Entry` with `kind: "note"` and
  `source: "notes"`, so notes flow through the universal data browser, search,
  timeline and realtime channels for free. This context owns the note-specific
  concerns: slug/path derivation, `[[wikilink]]` and `#tag` parsing, and
  maintenance of the `note_links` table (used for backlinks and, later, the
  note graph). All functions are scoped by `user_id`.

  Storage convention on the entry:
    * `title`            — the note title (last path segment)
    * `external_id`      — canonical full-path slug, unique per user
    * `data["body"]`     — raw markdown
    * `data["folder"]`   — parent path (e.g. "Projets/Servant"), "" at root
    * `data["tags"]`     — list of tags parsed from `#hashtags` in the body
  """

  import Ecto.Query

  alias Servant.Repo
  alias Servant.Data.Entry
  alias Servant.Notes.NoteLink

  @kind "note"
  @source "notes"

  @wikilink_re ~r/\[\[([^\]\[]+)\]\]/
  # `#tag` not preceded by a word char (so it ignores markdown headings, which
  # are `#` + space) and made of letters/digits/_/-/ nested paths.
  @tag_re ~r/(?<![\w#])#([\p{L}0-9_][\p{L}0-9_\/-]*)/u

  @doc "Lists a user's notes (entries of kind `note`), ordered for tree building."
  def list_notes(user_id) do
    notes_query(user_id)
    |> order_by([e], asc: e.external_id)
    |> Repo.all()
  end

  @doc "Fetches one note, raising if it does not exist or belongs to another user."
  def get_note!(user_id, id) do
    notes_query(user_id)
    |> where([e], e.id == ^id)
    |> Repo.one!()
  end

  def create_note(user_id, attrs) do
    {title, folder, body} = extract(attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entry_attrs = %{
      title: title,
      external_id: canon(full_path(folder, title)),
      occurred_at: now,
      data: %{"body" => body, "folder" => folder, "tags" => parse_tags(body)}
    }

    result =
      %Entry{user_id: user_id, kind: @kind, source: @source}
      |> note_changeset(entry_attrs)
      |> Repo.insert()

    after_write(user_id, result, :entry_created)
  end

  def update_note(user_id, id, attrs) do
    note = get_note!(user_id, id)
    {title, folder, body} = extract(attrs)

    entry_attrs = %{
      title: title,
      external_id: canon(full_path(folder, title)),
      data: %{"body" => body, "folder" => folder, "tags" => parse_tags(body)}
    }

    result =
      note
      |> note_changeset(entry_attrs)
      |> Repo.update()

    after_write(user_id, result, :entry_updated)
  end

  def delete_note(user_id, id) do
    note = get_note!(user_id, id)

    # note_links rows are dropped/nilified via FK on_delete; just remove the entry.
    case Repo.delete(note) do
      {:ok, note} ->
        broadcast(user_id, {:entry_deleted, note})
        {:ok, note}

      error ->
        error
    end
  end

  @doc """
  Returns the notes that link to `note` via a `[[wikilink]]` ("mentioned in"),
  deduped and excluding the note itself.
  """
  def backlinks(user_id, %Entry{} = note) do
    keys = note_keys(note)

    source_ids =
      from(l in NoteLink,
        where: l.user_id == ^user_id and l.target_path in ^keys,
        select: l.source_note_id,
        distinct: true
      )
      |> Repo.all()
      |> Enum.reject(&(&1 == note.id))

    notes_query(user_id)
    |> where([e], e.id in ^source_ids)
    |> order_by([e], asc: e.title)
    |> Repo.all()
  end

  @doc "Extracts canonical `[[wikilink]]` targets from markdown body."
  def parse_wikilinks(body) when is_binary(body) do
    @wikilink_re
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [target] -> canon(target) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_wikilinks(_), do: []

  @doc "Extracts `#hashtag` tags from markdown body (headings are ignored)."
  def parse_tags(body) when is_binary(body) do
    @tag_re
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [tag] -> tag end)
    |> Enum.uniq()
  end

  def parse_tags(_), do: []

  @doc """
  Recomputes a note's outgoing `note_links`: drops the old rows and inserts one
  per distinct wikilink target, resolving `target_note_id` when the target note
  already exists. Bulk-write pattern mirrors `Servant.Data.create_entries/2`.
  """
  def sync_links(user_id, %Entry{} = note) do
    targets = note.data |> Map.get("body", "") |> parse_wikilinks()
    Repo.delete_all(from l in NoteLink, where: l.source_note_id == ^note.id)

    if targets != [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      resolved = resolve_targets(user_id, targets)

      rows =
        Enum.map(targets, fn target ->
          %{
            id: Ecto.UUID.generate(),
            user_id: user_id,
            source_note_id: note.id,
            target_path: target,
            target_note_id: Map.get(resolved, target),
            inserted_at: now
          }
        end)

      Repo.insert_all(NoteLink, rows)
    end

    :ok
  end

  # ----- internals -----

  # A note needs a non-blank title (and thus a non-empty slug). validate_required
  # treats "" as missing, so it rejects empty titles before insert/update.
  defp note_changeset(entry, attrs) do
    entry
    |> Entry.changeset(attrs)
    |> Ecto.Changeset.validate_required([:title, :external_id])
  end

  defp after_write(user_id, {:ok, note}, event) do
    sync_links(user_id, note)
    resolve_inbound(user_id, note)
    broadcast(user_id, {event, note})
    {:ok, note}
  end

  defp after_write(_user_id, error, _event), do: error

  # Point any existing links whose target matches this note's keys at it, so the
  # graph stays accurate when a linked-to note is created or renamed later.
  defp resolve_inbound(user_id, %Entry{} = note) do
    keys = note_keys(note)

    from(l in NoteLink, where: l.user_id == ^user_id and l.target_path in ^keys)
    |> Repo.update_all(set: [target_note_id: note.id])

    :ok
  end

  # Maps each target string to a note id when a matching note exists.
  defp resolve_targets(user_id, targets) do
    notes_query(user_id)
    |> Repo.all()
    |> Enum.flat_map(fn note -> Enum.map(note_keys(note), &{&1, note.id}) end)
    |> Map.new()
    |> Map.take(targets)
  end

  defp notes_query(user_id) do
    from(e in Entry, where: e.user_id == ^user_id and e.kind == ^@kind and e.source == ^@source)
  end

  # A note is reachable as `[[title]]` or `[[folder/title]]`.
  defp note_keys(%Entry{} = note) do
    folder = note.data |> Map.get("folder", "") |> to_string()
    [canon(note.title || ""), canon(full_path(folder, note.title || ""))] |> Enum.uniq()
  end

  defp extract(attrs) do
    title = attrs |> get(:title) |> to_string() |> String.trim()
    folder = attrs |> get(:folder) |> to_string() |> String.trim() |> String.trim("/")
    body = attrs |> get(:body) |> to_string()
    {title, folder, body}
  end

  defp get(attrs, key), do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)

  defp full_path("", title), do: title
  defp full_path(folder, title), do: folder <> "/" <> title

  # Canonical form for slugs and link matching: trimmed, lower-cased, internal
  # whitespace collapsed. Keeps slashes (path separators) and accents.
  defp canon(str) do
    str
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  defp broadcast(user_id, message) do
    Phoenix.PubSub.broadcast(Servant.PubSub, "data:#{user_id}", message)
  end
end
