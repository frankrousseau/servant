defmodule Servant.Connectors.GitlabConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.GitlabConnector

  @valid %{"token" => "glpat-abc", "author" => "frank@example.com"}

  describe "init/2" do
    test "succeeds with token and author, defaulting the instance URL" do
      assert {:ok, state} = GitlabConnector.init(%{}, @valid)
      assert state.token == "glpat-abc"
      assert state.author == "frank@example.com"
      assert state.base_url == "https://gitlab.com"
      assert state.cursors == %{}
    end

    test "normalizes a self-hosted instance URL and carries cursors" do
      config =
        Map.merge(@valid, %{
          "base_url" => "https://git.example.com/ ",
          "cursors" => %{"42" => "2026-07-01T10:00:00Z"}
        })

      assert {:ok, state} = GitlabConnector.init(%{}, config)
      assert state.base_url == "https://git.example.com"
      assert state.cursors == %{"42" => "2026-07-01T10:00:00Z"}
    end

    test "requires each credential" do
      assert {:error, "token is required"} = GitlabConnector.init(%{}, %{})

      assert {:error, "author is required"} =
               GitlabConnector.init(%{}, %{"token" => "glpat-abc"})
    end
  end

  describe "persisted_config/1" do
    test "persists the per-project cursor map" do
      state = %{cursors: %{"42" => "2026-07-01T10:00:00Z"}}

      assert GitlabConnector.persisted_config(state) == %{
               "cursors" => %{"42" => "2026-07-01T10:00:00Z"}
             }
    end
  end

  describe "build_entry/2" do
    @project %{
      "id" => 42,
      "path_with_namespace" => "cgwire/kitsu",
      "visibility" => "private"
    }

    @commit %{
      "id" => "abc123",
      "message" => "Fix the thing\n\nLonger explanation.",
      "author_name" => "Frank",
      "author_email" => "frank@example.com",
      "authored_date" => "2026-07-10T11:30:00+02:00",
      "committed_date" => "2026-07-10T11:31:00+02:00",
      "web_url" => "https://gitlab.com/cgwire/kitsu/-/commit/abc123"
    }

    test "maps a commit to an entry, normalizing dates to UTC" do
      entry = GitlabConnector.build_entry(@commit, @project)

      assert entry["kind"] == "commit"
      assert entry["source"] == "gitlab"
      assert entry["external_id"] == "abc123"
      assert entry["title"] == "cgwire/kitsu - Fix the thing"
      assert entry["occurred_at"] == ~U[2026-07-10 09:30:00Z]
      assert entry["data"]["repo"] == "cgwire/kitsu"
      assert entry["data"]["message"] == "Fix the thing\n\nLonger explanation."
      assert entry["data"]["author_email"] == "frank@example.com"
      assert entry["data"]["committed_at"] == "2026-07-10T11:31:00+02:00"
      assert entry["metadata"]["repo_private"] == true
    end

    test "tolerates missing fields" do
      entry = GitlabConnector.build_entry(%{"id" => "def456"}, %{})

      assert entry["external_id"] == "def456"
      assert entry["data"]["message"] == ""
      assert %DateTime{} = entry["occurred_at"]
    end
  end

  describe "metadata" do
    test "id/kind and no continuous schedule" do
      assert GitlabConnector.id() == "gitlab"
      assert GitlabConnector.kind() == "commit"
      refute "continuous" in GitlabConnector.supported_schedules()
    end
  end
end
