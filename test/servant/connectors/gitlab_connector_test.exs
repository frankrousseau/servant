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

  describe "sync/1" do
    @kitsu %{"id" => 42, "path_with_namespace" => "cgwire/kitsu", "visibility" => "private"}
    @zou %{"id" => 43, "path_with_namespace" => "cgwire/zou", "visibility" => "public"}

    defp commit(sha, committed_date) do
      %{
        "id" => sha,
        "message" => "Work on #{sha}",
        "authored_date" => committed_date,
        "committed_date" => committed_date,
        "web_url" => "https://gitlab.com/c/#{sha}"
      }
    end

    # Routes the two GitLab endpoints the connector walks; `commits` is keyed
    # by project id.
    defp stub_gitlab(projects, commits) do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert Plug.Conn.get_req_header(conn, "private-token") == ["glpat-abc"]

        case conn.request_path do
          "/api/v4/projects" ->
            assert conn.params["membership"] == "true"
            Req.Test.json(conn, projects)

          "/api/v4/projects/" <> rest ->
            [id | _] = String.split(rest, "/")
            assert conn.params["author"] == "frank@example.com"
            Req.Test.json(conn, Map.get(commits, id, []))
        end
      end)
    end

    defp state(config \\ %{}) do
      {:ok, state} = GitlabConnector.init(%{}, Map.merge(@valid, config))
      state
    end

    test "walks every project and records a cursor per project" do
      stub_gitlab([@kitsu, @zou], %{
        "42" => [commit("aaa", "2026-07-10T11:30:00+02:00")],
        "43" => [
          commit("bbb", "2026-07-01T10:00:00Z"),
          commit("ccc", "2026-07-09T10:00:00Z")
        ]
      })

      assert {:ok, entries, new_state} = GitlabConnector.sync(state())

      assert Enum.map(entries, & &1["external_id"]) == ["aaa", "bbb", "ccc"]
      assert hd(entries)["title"] == "cgwire/kitsu - Work on aaa"

      # The cursor is the latest committed_date, compared as a DateTime and
      # not lexicographically (offsets would break string ordering)
      assert new_state.cursors == %{
               "42" => "2026-07-10T09:30:00Z",
               "43" => "2026-07-09T10:00:00Z"
             }
    end

    test "sends the stored cursor as the since bound" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.request_path do
          "/api/v4/projects" ->
            Req.Test.json(conn, [@kitsu])

          _ ->
            assert conn.params["since"] == "2026-07-01T10:00:00Z"
            Req.Test.json(conn, [])
        end
      end)

      state = state(%{"cursors" => %{"42" => "2026-07-01T10:00:00Z"}})
      assert {:ok, [], new_state} = GitlabConnector.sync(state)
      # No commits: the cursor stays where it was
      assert new_state.cursors == %{"42" => "2026-07-01T10:00:00Z"}
    end

    test "a project whose commits fail is skipped, keeping its cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/api/v4/projects" ->
            Req.Test.json(conn, [@kitsu, @zou])

          "/api/v4/projects/42/repository/commits" ->
            Plug.Conn.send_resp(conn, 403, "forbidden")

          _ ->
            Req.Test.json(conn, [commit("bbb", "2026-07-09T10:00:00Z")])
        end
      end)

      state = state(%{"cursors" => %{"42" => "2026-07-01T10:00:00Z"}})
      assert {:ok, entries, new_state} = GitlabConnector.sync(state)

      assert Enum.map(entries, & &1["external_id"]) == ["bbb"]
      assert new_state.cursors["42"] == "2026-07-01T10:00:00Z"
      assert new_state.cursors["43"] == "2026-07-09T10:00:00Z"
    end

    test "forgets the cursor of a project the user left" do
      stub_gitlab([@kitsu], %{"42" => []})

      state =
        state(%{"cursors" => %{"42" => "2026-07-01T10:00:00Z", "99" => "2026-01-01T00:00:00Z"}})

      assert {:ok, [], new_state} = GitlabConnector.sync(state)
      assert Map.keys(new_state.cursors) == ["42"]
    end

    test "a failing project listing fails the sync without touching the cursors" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end)

      state = state(%{"cursors" => %{"42" => "2026-07-01T10:00:00Z"}})
      assert {:error, message, ^state} = GitlabConnector.sync(state)
      assert message =~ "Unauthorized"
    end

    test "a rate limit is reported as such" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)

      assert {:error, message, _state} = GitlabConnector.sync(state())
      assert message =~ "rate limit"
    end

    test "an unexpected payload shape is an error, not a crash" do
      Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, %{"error" => "nope"}) end)

      assert {:error, message, _state} = GitlabConnector.sync(state())
      assert message =~ "unexpected projects payload"
    end

    test "paginates projects until a page comes back short" do
      full_page = for i <- 1..100, do: %{"id" => i, "path_with_namespace" => "p/#{i}"}

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "1"
        Req.Test.json(conn, full_page)
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "2"
        Req.Test.json(conn, [])
      end)

      Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, []) end)

      assert {:ok, [], new_state} = GitlabConnector.sync(state())
      assert map_size(new_state.cursors) == 100
    end
  end
end
