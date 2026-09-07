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

  describe "sync/1" do
    defp item(sha, date, repo \\ "cgwire/kitsu") do
      %{
        "sha" => sha,
        "html_url" => "https://github.com/#{repo}/commit/#{sha}",
        "repository" => %{"full_name" => repo, "private" => false},
        "commit" => %{
          "message" => "Work on #{sha}\n\nDetails.",
          "author" => %{"name" => "Frank", "email" => "frank@example.com", "date" => date},
          "committer" => %{"date" => date}
        }
      }
    end

    defp state(config \\ %{}) do
      {:ok, state} = GithubConnector.init(%{}, Map.merge(@valid, config))
      state
    end

    defp search_stub(items, total \\ nil) do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.request_path == "/search/commits"
        assert conn.params["sort"] == "author-date"
        assert conn.params["order"] == "asc"
        assert ["Bearer ghp_abc"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"items" => items, "total_count" => total || length(items)})
      end)
    end

    test "turns search results into commit entries and advances the cursor" do
      search_stub([
        item("aaa", "2026-07-01T10:00:00Z"),
        item("bbb", "2026-07-02T11:00:00Z")
      ])

      assert {:ok, entries, new_state} = GithubConnector.sync(state())

      assert Enum.map(entries, & &1["external_id"]) == ["aaa", "bbb"]
      assert hd(entries)["title"] == "cgwire/kitsu - Work on aaa"
      assert hd(entries)["occurred_at"] == ~U[2026-07-01 10:00:00Z]
      assert hd(entries)["data"]["author_email"] == "frank@example.com"

      # The newest author date becomes the cursor for the next sync
      assert new_state.last_author_date == "2026-07-02T11:00:00Z"

      assert GithubConnector.persisted_config(new_state) == %{
               "last_author_date" => "2026-07-02T11:00:00Z"
             }
    end

    test "asks only for commits at or after the cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["q"] == "author:frankrousseau author-date:>=2026-07-01T10:00:00Z"
        Req.Test.json(conn, %{"items" => [], "total_count" => 0})
      end)

      state = state(%{"last_author_date" => "2026-07-01T10:00:00Z"})
      assert {:ok, [], ^state} = GithubConnector.sync(state)
    end

    test "drops the repositories listed in exclude_repos" do
      search_stub([
        item("aaa", "2026-07-01T10:00:00Z", "cgwire/kitsu"),
        item("bbb", "2026-07-02T10:00:00Z", "someone/kitsu-copy"),
        item("ccc", "2026-07-03T10:00:00Z", "evil/anything")
      ])

      state = state(%{"exclude_repos" => "someone/kitsu-copy, evil/*"})
      assert {:ok, entries, new_state} = GithubConnector.sync(state)

      assert Enum.map(entries, & &1["external_id"]) == ["aaa"]
      # Excluded commits still move the cursor: they were seen, just not kept
      assert new_state.last_author_date == "2026-07-03T10:00:00Z"
    end

    test "pages through a window until a short page" do
      page = for i <- 1..100, do: item("sha#{i}", "2026-07-01T10:00:00Z")

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "1"
        assert conn.params["per_page"] == "100"
        Req.Test.json(conn, %{"items" => page, "total_count" => 150})
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "2"

        Req.Test.json(conn, %{
          "items" => [item("last", "2026-07-05T10:00:00Z")],
          "total_count" => 150
        })
      end)

      assert {:ok, entries, new_state} = GithubConnector.sync(state())
      assert length(entries) == 101
      assert new_state.last_author_date == "2026-07-05T10:00:00Z"
    end

    # GitHub caps a search at 1000 results, so a long history is walked in
    # successive author-date windows rather than one paged query.
    test "opens a new window when the search cap is hit" do
      full_page = fn day ->
        for i <- 1..100, do: item("sha-#{day}-#{i}", "2026-07-#{day}T10:00:00Z")
      end

      # First window: 10 full pages (the 1000-result cap), more results left
      for page <- 1..10 do
        Req.Test.expect(Servant.HTTP, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.params["page"] == to_string(page)
          assert conn.params["q"] == "author:frankrousseau"
          Req.Test.json(conn, %{"items" => full_page.("01"), "total_count" => 1200})
        end)
      end

      # Second window resumes from the newest date of the first
      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["q"] == "author:frankrousseau author-date:>=2026-07-01T10:00:00Z"

        Req.Test.json(conn, %{
          "items" => [item("tail", "2026-07-09T10:00:00Z")],
          "total_count" => 1
        })
      end)

      assert {:ok, entries, new_state} = GithubConnector.sync(state())
      assert length(entries) == 1001
      assert new_state.last_author_date == "2026-07-09T10:00:00Z"
    end

    # A backfill that dies halfway must keep what it already fetched: the
    # persisted cursor is what lets the next sync resume instead of restarting.
    test "keeps the commits already fetched when a later window fails" do
      for _page <- 1..10 do
        Req.Test.expect(Servant.HTTP, fn conn ->
          items = for i <- 1..100, do: item("sha#{i}", "2026-07-01T10:00:00Z")
          Req.Test.json(conn, %{"items" => items, "total_count" => 1200})
        end)
      end

      # 404, not 500: Req retries transient statuses on its own
      Req.Test.expect(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "boom") end)

      assert {:ok, entries, new_state} = GithubConnector.sync(state())
      assert length(entries) == 1000
      # The cursor sits at the end of the window that did succeed
      assert new_state.last_author_date == "2026-07-01T10:00:00Z"
    end

    test "maps the API failures to readable errors" do
      for {status, expected} <- [
            {401, "Unauthorized"},
            {403, "rate limit"},
            {404, "GitHub API error 404"}
          ] do
        Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, status, "") end)
        assert {:error, message, _state} = GithubConnector.sync(state())
        assert message =~ expected
      end
    end

    test "a rejected search reports GitHub's own message" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(422, Jason.encode!(%{"message" => "Invalid query"}))
      end)

      assert {:error, message, _state} = GithubConnector.sync(state())
      assert message =~ "GitHub rejected the search: Invalid query"
    end

    # A rate-limited response that advertises a delay is waited out and
    # retried, rather than failing the whole sync.
    test "waits out an advertised rate limit and retries" do
      Req.Test.expect(Servant.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> Plug.Conn.send_resp(403, "")
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "items" => [item("aaa", "2026-07-01T10:00:00Z")],
          "total_count" => 1
        })
      end)

      assert {:ok, [entry], _state} = GithubConnector.sync(state())
      assert entry["external_id"] == "aaa"
    end
  end
end
