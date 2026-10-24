defmodule Servant.PhotoShares.PhotoShare do
  @moduledoc """
  A public link over the photos that carry one or more tags or people
  (contacts tagged on the photo). Servant computes the feed at request time.
  As a result, a photo tagged after the creation of the link appears in the
  feed, and a photo leaves the feed when its tag is removed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @matches ~w(any all)
  @max_tags 20
  @max_people 20

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "photo_shares" do
    field :name, :string
    field :tags, {:array, :string}, default: []
    # [%{"id" => contact_id, "name" => name}]: the name is a label snapshot
    # for the lists of the owner. The match uses the id.
    field :people, {:array, :map}, default: []
    field :match, :string, default: "any"
    field :token, :string

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Returns the accepted `match` values: `any` (union of the tags) or `all` (intersection)."
  def matches, do: @matches

  # The context sets user_id and token programmatically. The changeset never
  # casts them from params.
  def changeset(share, attrs) do
    share
    |> cast(attrs, [:name, :tags, :people, :match])
    |> update_change(:name, &blank_to_nil/1)
    |> update_change(:tags, &normalize_tags/1)
    |> update_change(:people, &normalize_people/1)
    |> validate_required([:match])
    |> validate_length(:name, max: 100)
    |> validate_length(:tags, max: @max_tags)
    |> validate_length(:people, max: @max_people)
    |> validate_inclusion(:match, @matches)
    |> validate_criteria()
  end

  defp validate_criteria(changeset) do
    if get_field(changeset, :tags, []) == [] and get_field(changeset, :people, []) == [] do
      add_error(changeset, :tags, "pick at least one tag or person")
    else
      changeset
    end
  end

  defp blank_to_nil(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(name), do: name

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(tags), do: tags

  defp normalize_people(people) when is_list(people) do
    people
    |> Enum.flat_map(fn
      %{"id" => id} = person when is_binary(id) and id != "" ->
        name = if is_binary(person["name"]), do: String.slice(person["name"], 0, 100), else: ""
        [%{"id" => id, "name" => name}]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp normalize_people(people), do: people

  @doc "JSON shape for the management API, link included (the owner can copy it again)."
  def to_json(%__MODULE__{} = share) do
    %{
      id: share.id,
      name: share.name,
      tags: share.tags,
      people: share.people,
      match: share.match,
      token: share.token,
      path: "/share/#{share.token}",
      inserted_at: share.inserted_at
    }
  end
end
