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

    test "parses the exclude_repos list" do
      config = Map.put(@valid, "exclude_repos", "Satz0249/heliakitsu, evil/*\nother/repo")
      assert {:ok, state} = GithubConnector.init(%{}, config)
      assert state.exclude_repos == ["satz0249/heliakitsu", "evil/*", "other/repo"]
    end
  end

  describe "rate_limit_wait_ms/2" do
    defp resp(headers) do
      %Req.Response{status: 403, headers: Map.new(headers, fn {k, v} -> {k, [v]} end)}
    end

    test "honors retry-after, clamped to sane bounds" do
      assert GithubConnector.rate_limit_wait_ms(resp([{"retry-after", "30"}]), 0) == 30_000
      assert GithubConnector.rate_limit_wait_ms(resp([{"retry-after", "0"}]), 0) == 1_000
      assert GithubConnector.rate_limit_wait_ms(resp([{"retry-after", "999"}]), 0) == 90_000
    end

    test "falls back to x-ratelimit-reset when the quota is exhausted" do
      headers = [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1100"}]
      assert GithubConnector.rate_limit_wait_ms(resp(headers), 1085) == 15_000
    end

    test "a 403 without rate-limit headers is not a wait" do
      assert GithubConnector.rate_limit_wait_ms(resp([]), 0) == nil

      headers = [{"x-ratelimit-remaining", "12"}, {"x-ratelimit-reset", "1100"}]
      assert GithubConnector.rate_limit_wait_ms(resp(headers), 1085) == nil
    end
  end

  describe "excluded_repo?/2" do
    test "matches exact repos and owner wildcards, case-insensitively" do
      patterns = ["satz0249/heliakitsu", "evil/*"]

      assert GithubConnector.excluded_repo?("Satz0249/HeliaKitsu", patterns)
      assert GithubConnector.excluded_repo?("evil/anything", patterns)
      refute GithubConnector.excluded_repo?("cgwire/kitsu", patterns)
      refute GithubConnector.excluded_repo?(nil, patterns)
      refute GithubConnector.excluded_repo?("satz0249/heliakitsu", [])
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
