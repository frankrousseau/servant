defmodule Servant.Connectors.GithubConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.GithubConnector

  @valid %{"token" => "ghp_abc", "username" => "frankrousseau"}

  describe "init/2" do
    test "succeeds with token and username" do
      assert {:ok, state} = GithubConnector.init(%{}, @valid)
      assert state.token == "ghp_abc"
      assert state.username == "frankrousseau"
      assert state.last_author_date == nil
    end

    test "carries a persisted last_author_date cursor" do
      config = Map.put(@valid, "last_author_date", "2026-07-01T10:00:00Z")
      assert {:ok, state} = GithubConnector.init(%{}, config)
      assert state.last_author_date == "2026-07-01T10:00:00Z"
    end

    test "requires each credential" do
      assert {:error, "token is required"} = GithubConnector.init(%{}, %{})

      assert {:error, "username is required"} =
               GithubConnector.init(%{}, %{"token" => "ghp_abc"})
    end
  end

  describe "persisted_config/1" do
    test "persists the cursor" do
      state = %{last_author_date: "2026-07-01T10:00:00Z"}

      assert GithubConnector.persisted_config(state) == %{
               "last_author_date" => "2026-07-01T10:00:00Z"
             }
    end
  end

  describe "build_entry/1" do
    @item %{
      "sha" => "abc123",
      "html_url" => "https://github.com/frank/servant/commit/abc123",
      "commit" => %{
        "message" => "Fix the thing\n\nLonger explanation.",
        "author" => %{
          "name" => "Frank",
          "email" => "frank@example.com",
          "date" => "2026-07-10T09:30:00Z"
        },
        "committer" => %{"date" => "2026-07-10T09:31:00Z"}
      },
      "repository" => %{"full_name" => "frank/servant", "private" => true}
    }

    test "maps a search item to a commit entry" do
      entry = GithubConnector.build_entry(@item)

      assert entry["kind"] == "commit"
      assert entry["source"] == "github"
      assert entry["external_id"] == "abc123"
      assert entry["title"] == "frank/servant - Fix the thing"
      assert entry["occurred_at"] == ~U[2026-07-10 09:30:00Z]
      assert entry["data"]["repo"] == "frank/servant"
      assert entry["data"]["message"] == "Fix the thing\n\nLonger explanation."
      assert entry["data"]["author_email"] == "frank@example.com"
      assert entry["data"]["committed_at"] == "2026-07-10T09:31:00Z"
      assert entry["metadata"]["repo_private"] == true
    end

    test "tolerates missing fields" do
      entry = GithubConnector.build_entry(%{"sha" => "def456"})

      assert entry["external_id"] == "def456"
      assert entry["data"]["message"] == ""
      assert %DateTime{} = entry["occurred_at"]
    end
  end

  describe "metadata" do
    test "id/kind and no continuous schedule" do
      assert GithubConnector.id() == "github"
      assert GithubConnector.kind() == "commit"
      refute "continuous" in GithubConnector.supported_schedules()
    end
  end
end
