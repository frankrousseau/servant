defmodule Servant.Notes do
  @moduledoc """
  The Notes context. A note is a `Servant.Data.Entry` with `kind: "note"` and
  `source: "notes"`. As a result, the notes go through the universal data
  browser, the search, the timeline and the realtime channels with no added
  work. This context owns the note-specific concerns:

  - the calculation of the slug and the path
  - the parse of `[[wikilink]]`, `@[[mention]]` (contacts and events) and
    `#tag`
  - the maintenance of the `note_links` table (for the backlinks, the mention
    lookups and, later, the note graph)

  `user_id` scopes all the functions.

  Storage convention on the entry:
    * `title`: the note title (last path segment)
    * `external_id`: canonical full-path slug, unique for each user
    * `data["body"]`: raw markdown
    * `data["folder"]`: parent path (for example "Projets/Servant"), "" at root
    * `data["tags"]`: list of the tags from the `#hashtags` in the body
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Notes.NoteLink
  alias Servant.Repo

  @kind "note"
  @source "notes"
  @mention_kinds ["contact", "event"]

  # `(?<!@)` prevents a match of a plain wikilink on the tail of `@[[mention]]`.
  @wikilink_re ~r/(?<!@)\[\[([^\]\[]+)\]\]/
  @mention_re ~r/@\[\[([^\]\[]+)\]\]/
  # Matches a `#tag` with no word char before it. As a result, it ignores the
  # markdown headings, which are `#` + space. A tag contains letters, digits,
  # `_`, `-` and `/` for nested paths.
  @tag_re ~r/(?<![\w#])#([\p{L}0-9_][\p{L}0-9_\/-]*)/u

  @doc "Lists the notes of a user (entries of kind `note`), sorted for the build of the tree."
  def list_notes(user_id) do
    notes_query(user_id)
    |> order_by([e], asc: e.external_id)
    |> Repo.all()
  end

  @doc "Fetches one note. Raises if the note does not exist or belongs to another user."
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
      data: %{
        "body" => body,
        "folder" => folder,
        "tags" => parse_tags(body),
        "favorite" => favorite(attrs, nil),
        "attachments" => attachments(attrs, nil)
      }
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

    # Capture the ids before the write. The links that resolve to this note at
    # this time are the links to rewrite if the rename changes its keys.
    # reconcile_inbound removes their resolution as part of after_write.
    inbound_ids = inbound_source_ids(note)

    entry_attrs = %{
      title: title,
      external_id: canon(full_path(folder, title)),
      data: %{
        "body" => body,
        "folder" => folder,
        "tags" => parse_tags(body),
        "favorite" => favorite(attrs, note),
        "attachments" => attachments(attrs, note)
      }
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

    # The FK on_delete drops or nilifies the note_links rows. Only remove the entry.
    case Repo.delete(note) do
      {:ok, note} ->
        broadcast(user_id, {:entry_deleted, note})
        {:ok, note}

      error ->
        error
    end
  end

  @doc """
  Returns the notes that link to `note` through a `[[wikilink]]` ("mentioned
  in"), without duplicates and without the note itself.
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
  event). The match uses the resolved target id.
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

  @doc "Extracts the canonical `[[wikilink]]` targets from a markdown body."
  def parse_wikilinks(body) when is_binary(body) do
    @wikilink_re
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [target] -> canon(target) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_wikilinks(_), do: []

  @doc "Extracts the canonical `@[[mention]]` targets (contacts, events) from a markdown body."
  def parse_mentions(body) when is_binary(body) do
    @mention_re
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [target] -> canon(target) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_mentions(_), do: []

  @doc "Extracts the `#hashtag` tags from a markdown body. Ignores the headings."
  def parse_tags(body) when is_binary(body) do
    @tag_re
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [tag] -> tag end)
    |> Enum.uniq()
  end

  def parse_tags(_), do: []

  @doc """
  Calculates the outgoing `note_links` of a note again. Drops the old rows.
  Then inserts one row for each distinct `[[wikilink]]` target (kind
  `"wikilink"`, resolved to a note) and one row for each distinct
  `@[[mention]]` target (kind `"mention"`, resolved to a contact or event
  entry). The bulk-write pattern mirrors `Servant.Data.create_entries/2`.
  """
  # `notes` can be a preloaded snapshot of the notes of the user. A batch
  # caller (rename propagation) then resolves the wikilink targets and does
  # not load the full vault again for each source. `nil` loads the snapshot
  # lazily for the path with one note.
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

  # A note must have a non-blank title (and as a result a non-empty slug).
  # validate_required sees "" as missing, so it rejects an empty title before
  # the insert or the update. The slug pre-check changes the unique-index
  # violation of the entries into a friendly `:title` error. The index stays
  # the backstop under concurrency.
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

  # Keep the resolution of the inbound links accurate after a create or a
  # rename. A link that resolved to this note and no longer matches its keys
  # loses its resolution. A link with a target that matches its keys points
  # at this note.
  defp reconcile_inbound(user_id, %Entry{} = note) do
    keys = note_keys(note)

    from(l in NoteLink,
      where:
        l.user_id == ^user_id and l.kind == "wikilink" and l.target_note_id == ^note.id and
          l.target_path not in ^keys
    )
    |> Repo.update_all(set: [target_note_id: nil])

    # Claim only the keys that this note owns without ambiguity. The full path
    # is always unique. But a bare `[[title]]` must stay unresolved when
    # several notes share that title (same rule as resolve_targets). If this
    # code claims it, the last-written note with that name takes all such
    # backlinks.
    claimable = claimable_keys(user_id, note)

    from(l in NoteLink,
      where: l.user_id == ^user_id and l.kind == "wikilink" and l.target_path in ^claimable
    )
    |> Repo.update_all(set: [target_note_id: note.id])

    :ok
  end

  defp claimable_keys(user_id, %Entry{} = note) do
    folder = note.data |> Map.get("folder", "") |> to_string()
    full = canon(full_path(folder, note.title || ""))
    title = canon(note.title || "")

    if title_unique?(user_id, note.id, title) do
      Enum.uniq([title, full])
    else
      [full]
    end
  end

  defp title_unique?(user_id, note_id, canon_title) do
    notes_query(user_id)
    |> where([e], e.id != ^note_id)
    |> select([e], e.title)
    |> Repo.all()
    |> Enum.all?(fn t -> canon(t || "") != canon_title end)
  end

  # Returns the ids of the notes with links that resolve to `note` at this
  # time. This includes `note` itself, so that a rename also rewrites the
  # self-links.
  defp inbound_source_ids(%Entry{} = note) do
    from(l in NoteLink,
      where: l.kind == "wikilink" and l.target_note_id == ^note.id,
      select: l.source_note_id,
      distinct: true
    )
    |> Repo.all()
  end

  # Obsidian-style rename propagation. When an update changes the keys of the
  # note, rewrite the `[[wikilinks]]` in the notes that pointed at it. The
  # `[[title]]` links get the new title, and the `[[folder/title]]` links get
  # the new full path. Then sync the outgoing links of those sources again, so
  # that all the links still resolve.
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
          # Take one snapshot of the vault and use it for the link re-sync of
          # each source. The rewrite changes only bodies (not titles or
          # paths), so the target keys are stable. This prevents a reload of
          # all the notes for each source (it was O(N × vault)).
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

  # Maps each target string to a note id when a note matches. A full-path key
  # (`folder/title`) is unique for each user and always wins. A bare `title`
  # key resolves only when exactly one note has it. If not, the link stays
  # unresolved and does not point at an arbitrary note with the same name.
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

  # Maps each mention string to the id of a contact or event entry when one
  # matches. You can mention a contact by its display name (or by its bare
  # title as a fallback) and an event by its title.
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

  # The titles of vcard contacts look like "Name - org - email" (the entries
  # created before July 2026 used " — "). The display name (or the first
  # segment of the title) is the handle that people type.
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

  # On update, attrs can be partial. A key that is absent from `attrs` keeps
  # the current value of the note. An explicit "" still clears the value,
  # because "" is truthy here.
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

  # Boolean-safe: the `get` helper above loses an explicit `false`. An absent
  # key keeps the current flag of the note. A present key becomes a strict
  # boolean.
  defp favorite(attrs, note) do
    case Map.get(attrs, "favorite", Map.get(attrs, :favorite)) do
      nil -> (note && note.data["favorite"]) == true
      value -> value == true
    end
  end

  # Returns the entry ids of the files attached to the note (Files app
  # entries). An absent key keeps the current list. A present key replaces the
  # full list, sanitized to a list of ids without duplicates. The resolution
  # stays client-side: a stale id (deleted file) renders as missing, and the
  # user can detach it.
  defp attachments(attrs, note) do
    case Map.get(attrs, "attachments", Map.get(attrs, :attachments)) do
      nil ->
        (note && note.data["attachments"]) || []

      list when is_list(list) ->
        list
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.uniq()

      _invalid ->
        (note && note.data["attachments"]) || []
    end
  end

  defp full_path("", title), do: title
  defp full_path(folder, title), do: folder <> "/" <> title

  # Canonical form for slugs and for the match of links: trimmed, lower-cased,
  # with collapsed internal whitespace. Keeps slashes (path separators) and
  # accents.
  defp canon(str) do
    str
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  defp broadcast(user_id, message), do: Servant.Events.broadcast(user_id, message)
end
