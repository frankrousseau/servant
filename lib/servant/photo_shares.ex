defmodule Servant.PhotoShares do
  @moduledoc """
  Public photo feeds.

  A share is a link with a random token. It gives access to the photos of the
  owner that have one or more tags or people (`any` of them, or `all` of
  them). Each person who has the link sees those photos, and only those
  photos. The JSON feed exposes a small number of neutral fields for each
  photo and the note of the owner. It exposes no EXIF location and no people,
  not even the people that the share selects on. The file route serves a file
  only when it belongs to a photo that is in the feed at that time.

  The token is stored as-is (not hashed), so that the owner can copy the link
  again from the Photos app. It has 192 random bits, so a guess of a token is
  not a realistic attack.
  """

  import Ecto.Query

  alias Servant.Data
  alias Servant.Data.Entry
  alias Servant.PhotoShares.PhotoShare
  alias Servant.Repo
  alias Servant.Storage

  @token_bytes 24

  @spec list_shares(String.t()) :: [PhotoShare.t()]
  def list_shares(user_id) do
    PhotoShare
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @spec create_share(String.t(), map()) :: {:ok, PhotoShare.t()} | {:error, Ecto.Changeset.t()}
  def create_share(user_id, attrs) do
    %PhotoShare{}
    |> PhotoShare.changeset(attrs)
    |> Ecto.Changeset.put_change(:user_id, user_id)
    |> Ecto.Changeset.put_change(:token, generate_token())
    |> Repo.insert()
  end

  @spec delete_share(String.t(), String.t()) :: {:ok, PhotoShare.t()} | {:error, :not_found}
  def delete_share(user_id, id) do
    case Repo.get_by(PhotoShare, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      share -> Repo.delete(share)
    end
  end

  @doc "Returns the share of a public link, or nil (unknown or revoked token)."
  @spec get_by_token(String.t()) :: PhotoShare.t() | nil
  def get_by_token(token) when is_binary(token), do: Repo.get_by(PhotoShare, token: token)
  def get_by_token(_), do: nil

  @doc """
  Returns the photos of the owner that are in the feed at this time, newest
  first. `any` keeps a photo that has at least one of the tags or people of
  the share. `all` keeps a photo that has all of them.
  """
  @spec photos(PhotoShare.t()) :: [Entry.t()]
  def photos(%PhotoShare{} = share) do
    share.user_id
    |> Data.all_entries(%{"kind" => "photo"})
    |> Enum.filter(&in_feed?(share, &1))
  end

  @doc "Returns true if a photo entry belongs to the feed of the share."
  @spec in_feed?(PhotoShare.t(), Entry.t()) :: boolean()
  def in_feed?(%PhotoShare{tags: tags, people: people, match: match}, %Entry{data: data}) do
    photo_tags = for tag <- list(data["tags"]), is_binary(tag), do: {:tag, tag}
    photo_people = for %{"id" => id} <- list(data["people"]), do: {:person, id}
    held = MapSet.new(photo_tags ++ photo_people)

    wanted =
      Enum.map(tags || [], &{:tag, &1}) ++ Enum.map(people || [], &{:person, &1["id"]})

    case match do
      "all" -> Enum.all?(wanted, &MapSet.member?(held, &1))
      _ -> Enum.any?(wanted, &MapSet.member?(held, &1))
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  @doc """
  Resolves a storage-relative path that a request to the file route of the
  share gives. Returns `{:ok, absolute}` only when the file is the original,
  the thumbnail or the display copy of a photo that is in the feed at this
  time. As a result, a link never gives access to the other files of the
  owner.
  """
  @spec resolve_file(PhotoShare.t(), String.t()) :: {:ok, String.t()} | :error
  def resolve_file(%PhotoShare{} = share, relative) when is_binary(relative) do
    requested = normalize_relative(relative)

    allowed? =
      share
      |> photos()
      |> Enum.flat_map(&file_paths/1)
      |> Enum.any?(&(&1 == requested))

    if allowed?, do: Storage.resolve_owned_path(share.user_id, requested), else: :error
  end

  @doc "Returns the storage-relative paths of the photo files (original, thumbnail, display copy)."
  @spec file_paths(Entry.t()) :: [String.t()]
  def file_paths(%Entry{data: data}) do
    for key <- ["path", "thumb_path", "display_path"],
        public = data[key],
        is_binary(public) and public != "",
        do: normalize_relative(Storage.relative_from_public(public))
  end

  @doc """
  Returns the public JSON feed: the label of the share and, for each photo,
  only the data that is necessary for a viewer to browse it. The file URLs go
  through the file route of the share.
  """
  @spec feed_json(PhotoShare.t(), [Entry.t()]) :: map()
  def feed_json(%PhotoShare{} = share, photos) do
    %{
      name: share.name,
      tags: share.tags,
      match: share.match,
      photos: Enum.map(photos, &photo_json(share, &1))
    }
  end

  defp photo_json(share, %Entry{} = photo) do
    data = photo.data
    mime = data["mime_type"]
    video? = is_binary(mime) and String.starts_with?(mime, "video/")

    %{
      id: photo.id,
      title: photo.title,
      occurred_at: photo.occurred_at,
      mime_type: mime,
      video: video?,
      # The owner writes it for the people who get the link: it is context, not
      # metadata.
      note: data["note"],
      # The grid frame: the thumbnail, or the original if there is no
      # thumbnail. For a video without a captured frame, it is nothing, and
      # the page then shows a play tile.
      thumb: share_url(share, thumb_source(data, video?)),
      # The file that the viewer opens. The display copy is the fast 1920px JPEG.
      src: share_url(share, data["display_path"] || data["path"]),
      # The original, when it differs from the display copy.
      full: if(data["display_path"], do: share_url(share, data["path"]))
    }
  end

  # A video never uses its original as a grid frame. The page shows a play
  # tile and does not mount one decoder for each cell.
  defp thumb_source(data, true), do: data["thumb_path"]
  defp thumb_source(data, false), do: data["thumb_path"] || data["path"]

  defp share_url(_share, nil), do: nil

  defp share_url(share, public) when is_binary(public) do
    "/share/#{share.token}/files/" <> normalize_relative(Storage.relative_from_public(public))
  end

  defp normalize_relative(relative), do: relative |> URI.decode() |> String.trim_leading("/")

  defp generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
  end
end
