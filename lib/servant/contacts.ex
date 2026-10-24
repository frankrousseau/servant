defmodule Servant.Contacts do
  @moduledoc """
  Contact-specific operations on `contact` entries. The generic CRUD stays
  in `Servant.Data`.

  At this time, there is one operation: the merge of duplicates into one
  survivor. It is the only operation that must change several kinds at the
  same time, because these items refer to a contact id:

  - events (`data.contact_id`)
  - photos (`data.faces[].person_id`, `data.people[].id`)
  - the birthday and "me" prefs entries
  - the relations of other contacts
  - the mention links of the notes
  """

  import Ecto.Query

  alias Servant.CardDAV.VCard
  alias Servant.Data.Entry
  alias Servant.Events
  alias Servant.Notes.NoteLink
  alias Servant.Repo

  @kind "contact"

  # The fields that a merge copies. All the other data (raw CardDAV payloads,
  # ids of a source system) belongs to one card only and stays with the
  # survivor.
  @scalar_fields ~w(display_name org title url birthday address photo source_name)
  @list_fields ~w(emails phones)
  @referencing_kinds ~w(event photo prefs contact)
  @phone_suffix 9

  @doc """
  Merges `duplicate_ids` into the contact `survivor_id`.

  The survivor keeps its own values. Where it has no value, it takes the
  value of a duplicate. The merge makes the union of the emails, the phones,
  the tags and the relations, and concatenates the notes. Then it points each
  reference to a duplicate at the survivor and deletes the duplicates. All of
  this occurs in one transaction. The realtime events go out after the commit.

  Returns `{:ok, survivor}` or `{:error, reason}`. The reason is a string for
  a bad request (unknown id, not a contact, survivor in the list of
  duplicates).
  """
  @spec merge(String.t(), String.t(), [String.t()]) ::
          {:ok, Entry.t()} | {:error, String.t() | Ecto.Changeset.t()}
  def merge(user_id, survivor_id, duplicate_ids) when is_list(duplicate_ids) do
    duplicate_ids = Enum.uniq(duplicate_ids)

    with :ok <- validate_ids(survivor_id, duplicate_ids),
         {:ok, survivor} <- fetch_contact(user_id, survivor_id),
         {:ok, duplicates} <- fetch_contacts(user_id, duplicate_ids) do
      result =
        Repo.transaction(fn ->
          with {:ok, survivor} <- apply_merge(user_id, survivor, duplicates),
               {:ok, repointed} <- repoint_references(user_id, survivor, duplicate_ids),
               {:ok, deleted} <- delete_all(duplicates) do
            {survivor, repointed, deleted}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, {survivor, repointed, deleted}} ->
          Enum.each([survivor | repointed], &Events.broadcast(user_id, {:entry_updated, &1}))
          Enum.each(deleted, &Events.broadcast(user_id, {:entry_deleted, &1}))
          {:ok, survivor}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns the data of the survivor with the additions of the duplicates.

  - The non-blank values of the survivor win.
  - The lists become a union (survivor first, deduplicated on a normalized
    value).
  - The tags become a union.
  - The notes become a concatenation.
  - The relations become a union, without the relations that point at a
    merged contact.
  """
  @spec merge_data(map(), [map()], [String.t()]) :: map()
  def merge_data(survivor_data, duplicate_datas, merged_ids) do
    data =
      Enum.reduce(duplicate_datas, survivor_data, fn dup, acc ->
        acc
        |> fill_scalars(dup)
        |> union_lists(dup)
        |> Map.put("tags", union_tags(acc["tags"], dup["tags"]))
        |> Map.put("note", join_notes(acc["note"], dup["note"]))
      end)

    data
    |> Map.put("relations", union_relations(survivor_data, duplicate_datas, merged_ids))
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  @doc "Returns the entry title that the apps make for a contact: \"Name - org - title - email\"."
  @spec title_for(map()) :: String.t()
  def title_for(data) do
    name = blank_to_nil(data["display_name"]) || "Unnamed"
    first_email = data["emails"] |> List.wrap() |> Enum.map(&value_of/1) |> Enum.find(&(&1 != ""))

    [name, data["org"], data["title"], first_email]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  # ----- validation and loading -----

  defp validate_ids(survivor_id, duplicate_ids) do
    cond do
      duplicate_ids == [] -> {:error, "at least one duplicate is required"}
      survivor_id in duplicate_ids -> {:error, "the survivor cannot be one of the duplicates"}
      true -> :ok
    end
  end

  defp fetch_contact(user_id, id) do
    case fetch_contacts(user_id, [id]) do
      {:ok, [contact]} -> {:ok, contact}
      error -> error
    end
  end

  defp fetch_contacts(user_id, ids) do
    found =
      Entry
      |> where([e], e.user_id == ^user_id and e.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    cond do
      map_size(found) != length(ids) -> {:error, "unknown contact"}
      Enum.any?(found, fn {_id, entry} -> entry.kind != @kind end) -> {:error, "not a contact"}
      true -> {:ok, Enum.map(ids, &Map.fetch!(found, &1))}
    end
  end

  # ----- the survivor -----

  defp apply_merge(_user_id, survivor, duplicates) do
    merged_ids = [survivor.id | Enum.map(duplicates, & &1.id)]

    data =
      survivor.data
      |> merge_data(Enum.map(duplicates, & &1.data), merged_ids)
      |> inherit_carddav_identity(duplicates)

    survivor
    |> Entry.changeset(%{"data" => data, "title" => title_for(data)})
    |> Repo.update()
  end

  # A phone knows a contact by its resource name and UID. When the survivor
  # has no CardDAV identity and a duplicate has one, the survivor takes that
  # identity. The phone then sees an update of its contact, not a deletion.
  # The merge drops the raw payloads, so the merged fields give the merged
  # card.
  defp inherit_carddav_identity(data, duplicates) do
    phone = Enum.find(duplicates, &is_binary(&1.data["carddav_filename"]))

    if phone && !data["carddav_filename"] do
      data
      |> Map.drop(["carddav_vcf", "carddav_vcf_at"])
      |> Map.put("carddav_filename", phone.data["carddav_filename"])
      |> Map.put("carddav_uid", VCard.uid(phone))
    else
      data
    end
  end

  defp fill_scalars(acc, dup) do
    Enum.reduce(@scalar_fields, acc, fn key, acc ->
      if blank?(acc[key]), do: Map.put(acc, key, dup[key]), else: acc
    end)
  end

  defp union_lists(acc, dup) do
    Enum.reduce(@list_fields, acc, fn key, acc ->
      merged =
        (List.wrap(acc[key]) ++ List.wrap(dup[key]))
        |> Enum.filter(&(value_of(&1) != ""))
        |> Enum.uniq_by(&normalize_value(key, value_of(&1)))

      Map.put(acc, key, merged)
    end)
  end

  defp union_tags(a, b) do
    (List.wrap(a) ++ List.wrap(b))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp join_notes(a, b) do
    [a, b]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join("\n\n")
  end

  defp union_relations(survivor_data, duplicate_datas, merged_ids) do
    [survivor_data | duplicate_datas]
    |> Enum.flat_map(&List.wrap(&1["relations"]))
    |> Enum.filter(&relation?/1)
    |> Enum.reject(&(&1["contact_id"] in merged_ids))
    |> Enum.uniq_by(& &1["contact_id"])
  end

  defp relation?(%{"contact_id" => id, "type" => type}) when is_binary(id) and is_binary(type),
    do: String.trim(type) != ""

  defp relation?(_), do: false

  # ----- references in other entries -----

  defp repoint_references(user_id, survivor, duplicate_ids) do
    survivor_name = blank_to_nil(survivor.data["display_name"]) || survivor.title

    referencing_entries(user_id, duplicate_ids)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      data = rewrite_data(entry, survivor.id, survivor_name, duplicate_ids)

      if data == entry.data do
        {:cont, {:ok, acc}}
      else
        case entry |> Entry.changeset(%{"data" => data}) |> Repo.update() do
          {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
          error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, updated} ->
        NoteLink
        |> where([l], l.user_id == ^user_id and l.target_note_id in ^duplicate_ids)
        |> Repo.update_all(set: [target_note_id: survivor.id])

        {:ok, Enum.reverse(updated)}

      error ->
        error
    end
  end

  # The candidates are the entries of the referencing kinds that contain a
  # duplicate id in their JSON text. This is the same SQLite LIKE that the
  # palette search uses. The rewrite below then matches the exact fields.
  defp referencing_entries(user_id, duplicate_ids) do
    duplicate_ids
    |> Enum.flat_map(fn id ->
      pattern = "%" <> id <> "%"

      Entry
      |> where([e], e.user_id == ^user_id and e.kind in @referencing_kinds)
      |> where([e], fragment("? LIKE ?", e.data, ^pattern))
      |> Repo.all()
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp rewrite_data(%Entry{kind: "event", data: data}, survivor_id, _name, dup_ids) do
    if data["contact_id"] in dup_ids, do: Map.put(data, "contact_id", survivor_id), else: data
  end

  defp rewrite_data(%Entry{kind: "photo", data: data}, survivor_id, name, dup_ids) do
    faces =
      for face <- List.wrap(data["faces"]) do
        if is_map(face) and face["person_id"] in dup_ids do
          Map.merge(face, %{"person_id" => survivor_id, "person_name" => name})
        else
          face
        end
      end

    people =
      data["people"]
      |> List.wrap()
      |> Enum.map(fn person ->
        if is_map(person) and person["id"] in dup_ids,
          do: Map.merge(person, %{"id" => survivor_id, "name" => name}),
          else: person
      end)
      |> Enum.uniq_by(&if(is_map(&1), do: &1["id"], else: &1))

    data
    |> put_if_present("faces", faces)
    |> put_if_present("people", people)
  end

  defp rewrite_data(%Entry{kind: "prefs", data: data}, survivor_id, _name, dup_ids) do
    data =
      case data["contact_ids"] do
        ids when is_list(ids) ->
          remapped = ids |> Enum.map(&if(&1 in dup_ids, do: survivor_id, else: &1)) |> Enum.uniq()
          Map.put(data, "contact_ids", remapped)

        _ ->
          data
      end

    if data["contact_id"] in dup_ids, do: Map.put(data, "contact_id", survivor_id), else: data
  end

  defp rewrite_data(%Entry{kind: "contact", id: id, data: data}, survivor_id, _name, dup_ids) do
    case data["relations"] do
      relations when is_list(relations) ->
        remapped =
          relations
          |> Enum.map(fn relation ->
            if is_map(relation) and relation["contact_id"] in dup_ids,
              do: Map.put(relation, "contact_id", survivor_id),
              else: relation
          end)
          # A contact with a relation to a merged duplicate of itself now
          # points at itself. Drop that relation. Keep one relation for each
          # contact.
          |> Enum.reject(&(is_map(&1) and &1["contact_id"] == id))
          |> Enum.uniq_by(&if(is_map(&1), do: &1["contact_id"], else: &1))

        Map.put(data, "relations", remapped)

      _ ->
        data
    end
  end

  defp rewrite_data(%Entry{data: data}, _survivor_id, _name, _dup_ids), do: data

  defp put_if_present(data, key, value) do
    if Map.has_key?(data, key), do: Map.put(data, key, value), else: data
  end

  # ----- deletion -----

  defp delete_all(duplicates) do
    Enum.reduce_while(duplicates, {:ok, []}, fn entry, {:ok, acc} ->
      case Repo.delete(entry) do
        {:ok, deleted} -> {:cont, {:ok, [deleted | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  # ----- helpers -----

  defp value_of(%{"value" => value}) when is_binary(value), do: String.trim(value)
  defp value_of(value) when is_binary(value), do: String.trim(value)
  defp value_of(_), do: ""

  # Emails compare without case. Phones compare on their last digits. This is
  # the same rule as the duplicate detection of the app. As a result,
  # "+33 6 12 34 56 78" and "06 12 34 56 78" count as one line.
  defp normalize_value("emails", value), do: String.downcase(value)

  defp normalize_value("phones", value) do
    digits = String.replace(value, ~r/\D/, "")
    String.slice(digits, -@phone_suffix, @phone_suffix)
  end

  defp blank?(value), do: blank_to_nil(value) == nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
