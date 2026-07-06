defmodule Servant.Notes do
  @moduledoc """
  The Notes context. A note is a `Servant.Data.Entry` with `kind: "note"` and
  `source: "notes"`, so notes flow through the universal data browser, search,
  timeline and realtime channels for free. This context owns the note-specific
  concerns: slug/path derivation, `[[wikilink]]`, `@[[mention]]` (contacts and
  events) and `#tag` parsing, and maintenance of the `note_links` table (used
  for backlinks, mention lookups and, later, the note graph). All functions are
  scoped by `user_id`.

  Storage convention on the entry:
    * `title`: the note title (last path segment)
    * `external_id`: canonical full-path slug, unique per user
    * `data["body"]`: raw markdown
    * `data["folder"]`: parent path (e.g. "Projets/Servant"), "" at root
    * `data["tags"]`: list of tags parsed from `#hashtags` in the body
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Notes.NoteLink
  alias Servant.Repo

  @kind "note"
  @source "notes"
  @mention_kinds ["contact", "event"]

  # `(?<!@)` keeps plain wikilinks from also matching the tail of `@[[mention]]`.
  @wikilink_re ~r/(?<!@)\[\[([^\]\[]+)\]\]/
  @mention_re ~r/@\[\[([^\]\[]+)\]\]/
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
    now = DateTime.truncate(DateTime.utc_now(), :second)

    entry_attrs = %{
      title: title,
      external_id: canon(full_path(folder, title)),
      occurred_at: now,
      data: %{"body" => body, "folder" => folder, "tags" => parse_tags(body)}
    }

    result =
      %Entry{user_id: user_id, kind: @kind, source: @source}
      |> note_changeset(entry_attrs, user_id)
      |> Repo.insert()

    after_write(user_id, result, :entry_created)
  end

  def update_note(user_id, id, attrs) do
    note = get_note!(user_id, id)
    {title, folder, body} = extract(attrs, note)

    # Captured before the write: links that currently resolve to this note are
    # the ones to rewrite if the rename changes its keys (reconcile_inbound
    # un-resolves them as part of after_write).
    inbound_ids = inbound_source_ids(note)

    entry_attrs = %{
      title: title,
      external_id: canon(full_path(folder, title)),
      data: %{"body" => body, "folder" => folder, "tags" => parse_tags(body)}
    }

    result =
      note
      |> note_changeset(entry_attrs, user_id)
      |> Repo.update()

    case after_write(user_id, result, :entry_updated) do
      {:ok, updated} ->
        propagate_rename(user_id, note, updated, inbound_ids)
        {:ok, updated}

      error ->
        error
    end
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
        where: l.user_id == ^user_id and l.kind == "wikilink" and l.target_path in ^keys,
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

  @doc """
  Returns the notes that `@[[mention]]` the given entry (a contact or an
  event), matched by resolved target id.
  """
  def mentioning(user_id, entry_id) do
    source_ids =
      from(l in NoteLink,
        where: l.user_id == ^user_id and l.kind == "mention" and l.target_note_id == ^entry_id,
        select: l.source_note_id,
        distinct: true
      )
      |> Repo.all()

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

  @doc "Extracts canonical `@[[mention]]` targets (contacts/events) from markdown body."
  def parse_mentions(body) when is_binary(body) do
    @mention_re
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [target] -> canon(target) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_mentions(_), do: []

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
  per distinct `[[wikilink]]` target (kind `"wikilink"`, resolved to a note)
  and per distinct `@[[mention]]` target (kind `"mention"`, resolved to a
  contact/event entry). Bulk-write pattern mirrors `Servant.Data.create_entries/2`.
  """
  # `notes` may be a preloaded snapshot of the user's notes so a batch caller
  # (rename propagation) resolves wikilink targets without reloading the whole
  # vault once per source. `nil` loads it lazily for the single-note path.
  def sync_links(user_id, %Entry{} = note, notes \\ nil) do
    body = Map.get(note.data, "body", "")
    wikilinks = parse_wikilinks(body)
    mentions = parse_mentions(body)

    Repo.delete_all(from l in NoteLink, where: l.source_note_id == ^note.id)

    rows =
      link_rows(user_id, note, wikilinks, resolve_targets(user_id, wikilinks, notes), "wikilink") ++
        link_rows(user_id, note, mentions, resolve_mentions(user_id, mentions), "mention")

    if rows != [], do: Repo.insert_all(NoteLink, rows)

    :ok
  end

  defp link_rows(user_id, note, targets, resolved, kind) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Enum.map(targets, fn target ->
      %{
        id: Ecto.UUID.generate(),
        user_id: user_id,
        source_note_id: note.id,
        target_path: target,
        target_note_id: Map.get(resolved, target),
        kind: kind,
        inserted_at: now
      }
    end)
  end

  # ----- internals -----

  # A note needs a non-blank title (and thus a non-empty slug). validate_required
  # treats "" as missing, so it rejects empty titles before insert/update.
  # The slug pre-check turns the entries unique-index violation into a friendly
  # `:title` error (the index is still the backstop under concurrency).
  defp note_changeset(entry, attrs, user_id) do
    entry
    |> Entry.changeset(attrs)
    |> Ecto.Changeset.validate_required([:title, :external_id])
    |> validate_slug_available(user_id)
  end

  defp validate_slug_available(changeset, user_id) do
    slug = Ecto.Changeset.get_field(changeset, :external_id)
    id = Ecto.Changeset.get_field(changeset, :id)

    taken? =
      is_binary(slug) and slug != "" and
        notes_query(user_id)
        |> where([e], e.external_id == ^slug)
        |> then(fn q -> if id, do: where(q, [e], e.id != ^id), else: q end)
        |> Repo.exists?()

    if taken? do
      Ecto.Changeset.add_error(
        changeset,
        :title,
        "a note with this title already exists in this folder"
      )
    else
      changeset
    end
  end

  defp after_write(user_id, {:ok, note}, event) do
    {:ok, _} =
      Repo.transaction(fn ->
        sync_links(user_id, note)
        reconcile_inbound(user_id, note)
      end)

    broadcast(user_id, {event, note})
    {:ok, note}
  end

  defp after_write(_user_id, error, _event), do: error

  # Keep inbound link resolution accurate across creates and renames: links that
  # used to resolve to this note but no longer match its keys are un-resolved,
  # and links whose target matches its keys are pointed at it.
  defp reconcile_inbound(user_id, %Entry{} = note) do
    keys = note_keys(note)

    from(l in NoteLink,
      where:
        l.user_id == ^user_id and l.kind == "wikilink" and l.target_note_id == ^note.id and
          l.target_path not in ^keys
    )
    |> Repo.update_all(set: [target_note_id: nil])

    from(l in NoteLink,
      where: l.user_id == ^user_id and l.kind == "wikilink" and l.target_path in ^keys
    )
    |> Repo.update_all(set: [target_note_id: note.id])

    :ok
  end

  # Ids of notes whose links currently resolve to `note` (including itself, so
  # self-links get rewritten on rename too).
  defp inbound_source_ids(%Entry{} = note) do
    from(l in NoteLink,
      where: l.kind == "wikilink" and l.target_note_id == ^note.id,
      select: l.source_note_id,
      distinct: true
    )
    |> Repo.all()
  end

  # Obsidian-style rename propagation: when an update changes the note's keys,
  # rewrite `[[wikilinks]]` in the notes that pointed at it (`[[title]]` links
  # get the new title, `[[folder/title]]` links the new full path), then
  # re-sync those sources' outgoing links so everything still resolves.
  defp propagate_rename(_user_id, _old_note, _note, []), do: :ok

  defp propagate_rename(user_id, %Entry{} = old_note, %Entry{} = note, source_ids) do
    stale = note_keys(old_note) -- note_keys(note)

    replacements =
      %{}
      |> Map.put(
        canon(full_path(old_note.data["folder"] || "", old_note.title || "")),
        full_path(note.data["folder"] || "", note.title || "")
      )
      |> Map.put(canon(old_note.title || ""), note.title || "")
      |> Map.take(stale)

    if replacements == %{} do
      :ok
    else
      {:ok, rewritten} =
        Repo.transaction(fn ->
          # Snapshot the vault once and reuse it for every source's link re-sync:
          # rewriting only changes bodies (not titles/paths), so target keys are
          # stable; avoids reloading all notes per source (was O(N × vault)).
          all_notes = Repo.all(notes_query(user_id))

          all_notes
          |> Enum.filter(&(&1.id in source_ids))
          |> Enum.flat_map(&rewrite_source(user_id, &1, replacements, all_notes))
        end)

      Enum.each(rewritten, &broadcast(user_id, {:entry_updated, &1}))
      :ok
    end
  end

  defp rewrite_source(user_id, %Entry{} = source, replacements, all_notes) do
    body = source.data["body"] || ""
    new_body = rewrite_wikilinks(body, replacements)

    if new_body == body do
      []
    else
      data =
        source.data
        |> Map.put("body", new_body)
        |> Map.put("tags", parse_tags(new_body))

      {:ok, updated} = source |> Ecto.Changeset.change(data: data) |> Repo.update()
      sync_links(user_id, updated, all_notes)
      [updated]
    end
  end

  defp rewrite_wikilinks(body, replacements) do
    Regex.replace(@wikilink_re, body, fn full, target ->
      case Map.fetch(replacements, canon(target)) do
        {:ok, new_target} -> "[[#{new_target}]]"
        :error -> full
      end
    end)
  end

  # Maps each target string to a note id when a matching note exists. A
  # full-path key (`folder/title`) is unique per user and always wins; a bare
  # `title` key only resolves when exactly one note carries it; otherwise the
  # link is left unresolved rather than pointing at an arbitrary same-named note.
  defp resolve_targets(_user_id, [], _notes), do: %{}

  defp resolve_targets(user_id, targets, notes) do
    notes = notes || Repo.all(notes_query(user_id))

    by_path =
      Map.new(notes, fn note ->
        folder = note.data |> Map.get("folder", "") |> to_string()
        {canon(full_path(folder, note.title || "")), note.id}
      end)

    by_title =
      notes
      |> Enum.group_by(fn note -> canon(note.title || "") end, & &1.id)
      |> Enum.flat_map(fn
        {title, [id]} -> [{title, id}]
        {_title, _ids} -> []
      end)
      |> Map.new()

    by_title
    |> Map.merge(by_path)
    |> Map.take(targets)
  end

  # Maps each mention string to a contact/event entry id when one matches. A
  # contact is mentionable by its display name (or bare title as fallback), an
  # event by its title.
  defp resolve_mentions(_user_id, []), do: %{}

  defp resolve_mentions(user_id, names) do
    from(e in Entry,
      where: e.user_id == ^user_id and e.kind in ^@mention_kinds,
      select: {e.id, e.title, fragment("json_extract(?, '$.display_name')", e.data)}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {id, title, display_name} ->
      for key <- mention_keys(title, display_name), key != "", do: {key, id}
    end)
    |> Map.new()
    |> Map.take(names)
  end

  # vcard contact titles look like "Name - org - email" (entries created
  # before July 2026 used " — "); the display name (or the title's first
  # segment) is the handle people actually type.
  defp mention_keys(title, display_name) do
    title = to_string(title)

    [
      canon(to_string(display_name)),
      canon(title),
      title |> String.split([" - ", " — "]) |> hd() |> canon()
    ]
    |> Enum.uniq()
  end

  defp notes_query(user_id) do
    from(e in Entry, where: e.user_id == ^user_id and e.kind == ^@kind and e.source == ^@source)
  end

  # A note is reachable as `[[title]]` or `[[folder/title]]`.
  defp note_keys(%Entry{} = note) do
    folder = note.data |> Map.get("folder", "") |> to_string()
    [canon(note.title || ""), canon(full_path(folder, note.title || ""))] |> Enum.uniq()
  end

  # On update, attrs may be partial: keys absent from `attrs` keep the note's
  # current value (explicit "" still clears, since "" is truthy here).
  defp extract(attrs, note \\ nil) do
    title = attrs |> get(:title, note && note.title) |> to_string() |> String.trim()

    folder =
      attrs
      |> get(:folder, note && note.data["folder"])
      |> to_string()
      |> String.trim()
      |> String.trim("/")

    body = attrs |> get(:body, note && note.data["body"]) |> to_string()
    {title, folder, body}
  end

  defp get(attrs, key, default),
    do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key) || default

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

  defp broadcast(user_id, message), do: Servant.Events.broadcast(user_id, message)
end
