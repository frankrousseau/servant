defmodule Servant.PhotoSharesTest do
  # SQLite: user inserts from two async modules collide ("Database busy"); keep serial.
  use Servant.DataCase, async: false

  alias Servant.PhotoShares
  alias Servant.PhotoShares.PhotoShare

  defp user, do: Servant.Fixtures.user_fixture()

  defp photo(user_id, tags, extra \\ %{}) do
    Servant.Fixtures.entry_fixture(user_id, %{
      "kind" => "photo",
      "source" => "photos",
      "title" => Enum.join(tags, "+"),
      "data" =>
        Map.merge(
          %{
            "path" => "/files/#{user_id}/apps/photos/#{Ecto.UUID.generate()}.jpg",
            "tags" => tags
          },
          extra
        )
    })
  end

  describe "create_share/2" do
    test "generates a token, trims tags and blanks the name" do
      u = user()

      {:ok, share} =
        PhotoShares.create_share(u.id, %{
          "name" => "  ",
          "tags" => [" holidays ", "beach", "beach", ""]
        })

      assert String.length(share.token) == 32
      assert share.tags == ["holidays", "beach"]
      assert share.match == "any"
      assert share.name == nil
      assert PhotoShare.to_json(share).path == "/share/#{share.token}"
    end

    test "rejects an empty tag list and an unknown match" do
      u = user()
      assert {:error, %Ecto.Changeset{}} = PhotoShares.create_share(u.id, %{"tags" => []})

      assert {:error, %Ecto.Changeset{}} =
               PhotoShares.create_share(u.id, %{"tags" => ["a"], "match" => "some"})
    end
  end

  describe "photos/1" do
    test "any: photos carrying at least one tag, newest first, this user only" do
      u = user()
      other = user()
      beach = photo(u.id, ["beach"])
      both = photo(u.id, ["beach", "family"])
      _plain = photo(u.id, [])
      _untagged = photo(u.id, ["work"])
      _foreign = photo(other.id, ["beach"])

      {:ok, share} = PhotoShares.create_share(u.id, %{"tags" => ["beach", "family"]})

      ids = share |> PhotoShares.photos() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([beach.id, both.id])
    end

    test "all: only the photos carrying every tag" do
      u = user()
      _beach = photo(u.id, ["beach"])
      both = photo(u.id, ["beach", "family"])

      {:ok, share} =
        PhotoShares.create_share(u.id, %{"tags" => ["beach", "family"], "match" => "all"})

      assert Enum.map(PhotoShares.photos(share), & &1.id) == [both.id]
    end

    test "follows later tag changes (the feed is computed on read)" do
      u = user()
      entry = photo(u.id, ["beach"])
      {:ok, share} = PhotoShares.create_share(u.id, %{"tags" => ["beach"]})
      assert length(PhotoShares.photos(share)) == 1

      {:ok, _} = Servant.Data.update_entry(u.id, entry.id, %{"data" => %{"tags" => []}})
      assert PhotoShares.photos(share) == []
    end
  end

  describe "feed_json/2" do
    test "exposes neutral fields and share-routed file URLs only" do
      u = user()

      entry =
        photo(u.id, ["beach"], %{
          "thumb_path" => "/files/#{u.id}/apps/photos/a_thumb.jpg",
          "display_path" => "/files/#{u.id}/apps/photos/a_display.jpg",
          "mime_type" => "image/jpeg",
          "latitude" => 48.85,
          "people" => [%{"id" => "x", "name" => "Someone"}]
        })

      {:ok, share} = PhotoShares.create_share(u.id, %{"tags" => ["beach"]})
      feed = PhotoShares.feed_json(share, PhotoShares.photos(share))

      assert [row] = feed.photos
      assert row.id == entry.id
      assert row.video == false
      assert row.thumb == "/share/#{share.token}/files/#{u.id}/apps/photos/a_thumb.jpg"
      assert row.src == "/share/#{share.token}/files/#{u.id}/apps/photos/a_display.jpg"
      assert String.ends_with?(row.full, ".jpg")
      refute Map.has_key?(row, :latitude)
      refute Map.has_key?(row, :people)
      refute Map.has_key?(row, :data)
    end

    test "a video without a captured frame has no thumb" do
      u = user()
      photo(u.id, ["clips"], %{"mime_type" => "video/mp4"})
      {:ok, share} = PhotoShares.create_share(u.id, %{"tags" => ["clips"]})

      assert [%{video: true, thumb: nil, src: src}] =
               PhotoShares.feed_json(share, PhotoShares.photos(share)).photos

      assert is_binary(src)
    end
  end

  describe "delete_share/2" do
    test "revokes the token and is scoped to the owner" do
      u = user()
      other = user()
      {:ok, share} = PhotoShares.create_share(u.id, %{"tags" => ["beach"]})

      assert {:error, :not_found} = PhotoShares.delete_share(other.id, share.id)
      assert {:ok, _} = PhotoShares.delete_share(u.id, share.id)
      assert PhotoShares.get_by_token(share.token) == nil
    end
  end
end
