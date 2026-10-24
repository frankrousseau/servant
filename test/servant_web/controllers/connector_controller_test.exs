defmodule ServantWeb.ConnectorControllerTest do
  use ServantWeb.ConnCase

  alias Servant.Connectors

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp create_strava(user_id) do
    {:ok, config} =
      Connectors.create_connector_config(user_id, %{
        "connector_type" => "strava",
        "name" => "My Strava",
        "config" => %{
          "client_id" => "cid",
          "client_secret" => "topsecret",
          "refresh_token" => "rt-123"
        }
      })

    config
  end

  describe "secret redaction" do
    test "show masks sensitive config values but keeps the rest", %{conn: conn, user: user} do
      config = create_strava(user.id)

      conn = get(conn, "/api/connectors/#{config.id}")
      assert %{"data" => %{"config" => cfg}} = json_response(conn, 200)

      assert cfg["client_secret"] == "••••••"
      assert cfg["refresh_token"] == "••••••"
      assert cfg["client_id"] == "cid"
    end

    test "updating with the mask keeps the stored secret", %{conn: conn, user: user} do
      config = create_strava(user.id)

      conn =
        put(conn, "/api/connectors/#{config.id}", %{
          "config" => %{
            "client_id" => "cid",
            "client_secret" => "••••••",
            "refresh_token" => "••••••"
          }
        })

      assert json_response(conn, 200)

      stored = Connectors.get_connector_config!(user.id, config.id)
      assert stored.config["client_secret"] == "topsecret"
      assert stored.config["refresh_token"] == "rt-123"
    end

    test "updating with a real value replaces the secret", %{conn: conn, user: user} do
      config = create_strava(user.id)

      conn =
        put(conn, "/api/connectors/#{config.id}", %{
          "config" => %{"client_secret" => "rotated-secret"}
        })

      assert json_response(conn, 200)
      stored = Connectors.get_connector_config!(user.id, config.id)
      assert stored.config["client_secret"] == "rotated-secret"
    end
  end

  describe "scoping" do
    test "cannot read another user's connector", %{conn: conn} do
      other = user_fixture()
      foreign = create_strava(other.id)
      assert_error_sent(404, fn -> get(conn, "/api/connectors/#{foreign.id}") end)
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/connectors")
      assert json_response(conn, 401)
    end
  end

  describe "index" do
    test "lists the current user's connectors, secrets redacted", %{conn: conn, user: user} do
      create_strava(user.id)
      create_strava(user_fixture().id)

      conn = get(conn, "/api/connectors")
      assert %{"data" => [connector]} = json_response(conn, 200)
      assert connector["name"] == "My Strava"
      assert connector["config"]["client_secret"] == "••••••"
    end
  end

  describe "create" do
    test "creates a connector", %{conn: conn} do
      conn =
        post(conn, "/api/connectors", %{
          "connector_type" => "rss",
          "name" => "Blog",
          "schedule" => "every_hour",
          "config" => %{"url" => "https://example.com/feed"}
        })

      assert %{"data" => connector} = json_response(conn, 201)
      assert connector["connector_type"] == "rss"
      assert connector["enabled"] == false
    end

    test "rejects a missing connector type", %{conn: conn} do
      conn = post(conn, "/api/connectors", %{"name" => "Nameless"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "rejects an unknown connector type", %{conn: conn} do
      conn = post(conn, "/api/connectors", %{"connector_type" => "myspace", "name" => "Nope"})
      assert %{"errors" => %{"connector_type" => _}} = json_response(conn, 422)
    end

    test "rejects an unsupported schedule", %{conn: conn} do
      params = %{"connector_type" => "rss", "name" => "Blog", "schedule" => "every_second"}
      conn = post(conn, "/api/connectors", params)
      assert %{"errors" => %{"schedule" => _}} = json_response(conn, 422)
    end
  end

  describe "delete" do
    test "deletes the connector", %{conn: conn, user: user} do
      config = create_strava(user.id)

      assert response(delete(conn, "/api/connectors/#{config.id}"), 204)
      assert Connectors.list_connector_configs(user.id) == []
    end

    test "cannot delete another user's connector", %{conn: conn} do
      foreign = create_strava(user_fixture().id)
      assert_error_sent(404, fn -> delete(conn, "/api/connectors/#{foreign.id}") end)
    end
  end

  describe "worker lifecycle" do
    defp create_bank(user_id) do
      {:ok, config} =
        Connectors.create_connector_config(user_id, %{
          "connector_type" => "bank_csv",
          "name" => "Bank",
          "schedule" => "on_demand"
        })

      config
    end

    setup %{user: user} do
      config = create_bank(user.id)
      on_exit(fn -> Connectors.stop_connector(user.id, config.id) end)
      %{config: config}
    end

    test "starts, reports already running, then stops", %{conn: conn, config: config} do
      assert %{"status" => "started"} =
               json_response(post(conn, "/api/connectors/#{config.id}/start"), 200)

      assert %{"status" => "already_running"} =
               json_response(post(conn, "/api/connectors/#{config.id}/start"), 200)

      assert %{"status" => "stopped"} =
               json_response(post(conn, "/api/connectors/#{config.id}/stop"), 200)

      # A second stop is not an error: the endpoint is idempotent.
      assert %{"status" => "stopped"} =
               json_response(post(conn, "/api/connectors/#{config.id}/stop"), 200)
    end

    test "sync is refused while the worker is stopped", %{conn: conn, config: config} do
      conn = post(conn, "/api/connectors/#{config.id}/sync")
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "not running"
    end

    test "sync is triggered once the worker runs", %{conn: conn, config: config, user: user} do
      post(conn, "/api/connectors/#{config.id}/start")

      assert %{"status" => "sync_triggered"} =
               json_response(post(conn, "/api/connectors/#{config.id}/sync"), 200)

      # Let the worker handle the cast before the test connection goes away.
      [{pid, _}] = Registry.lookup(Servant.Connectors.Registry, {user.id, config.id})
      _ = :sys.get_state(pid)
    end
  end

  describe "logs" do
    test "lists the sync logs of a connector", %{conn: conn, user: user} do
      config = create_strava(user.id)
      {:ok, log} = Connectors.create_sync_log(config.id)
      Connectors.complete_sync_log(log, 3)

      conn = get(conn, "/api/connectors/#{config.id}/logs")
      assert %{"data" => [entry]} = json_response(conn, 200)
      assert entry["status"] == "completed"
      assert entry["entries_count"] == 3
    end

    test "cannot read another user's logs", %{conn: conn} do
      foreign = create_strava(user_fixture().id)
      assert_error_sent(404, fn -> get(conn, "/api/connectors/#{foreign.id}/logs") end)
    end
  end

  describe "schedules" do
    test "returns the schedules a connector type supports", %{conn: conn} do
      conn = get(conn, "/api/connectors/schedules/bank_csv")
      assert %{"schedules" => ["on_demand"], "default" => "on_demand"} = json_response(conn, 200)
    end

    test "unknown connector type is a 404", %{conn: conn} do
      conn = get(conn, "/api/connectors/schedules/myspace")
      assert json_response(conn, 404)
    end
  end

  describe "import" do
    test "imports an uploaded CSV", %{conn: conn, user: user} do
      {:ok, config} =
        Connectors.create_connector_config(user.id, %{
          "connector_type" => "bank_csv",
          "name" => "Bank",
          "schedule" => "on_demand"
        })

      csv = "Date,Description,Amount,Currency\n2026-07-01,Coffee,-3.50,EUR\n"

      upload = %Plug.Upload{
        path: write_tmp(csv),
        filename: "ops.csv",
        content_type: "text/csv"
      }

      conn = post(multipart(conn), "/api/connectors/#{config.id}/import", %{"file" => upload})
      assert %{"status" => "ok", "imported" => 1} = json_response(conn, 200)
    end

    test "a connector that cannot import says so", %{conn: conn, user: user} do
      config = create_strava(user.id)
      upload = %Plug.Upload{path: write_tmp("x"), filename: "x.csv", content_type: "text/csv"}

      conn = post(multipart(conn), "/api/connectors/#{config.id}/import", %{"file" => upload})
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "does not support file import"
    end

    test "a form field that is not an upload is refused", %{conn: conn, user: user} do
      config = create_strava(user.id)
      conn = post(multipart(conn), "/api/connectors/#{config.id}/import", %{"file" => "oops"})
      assert %{"error" => "A file is required"} = json_response(conn, 422)
    end

    test "a request without a file is refused by the schema", %{conn: conn, user: user} do
      config = create_strava(user.id)
      conn = post(multipart(conn), "/api/connectors/#{config.id}/import", %{})
      assert %{"error" => _} = json_response(conn, 422)
    end

    defp multipart(conn) do
      put_req_header(conn, "content-type", "multipart/form-data; boundary=----test")
    end

    defp write_tmp(content) do
      path = Path.join(System.tmp_dir!(), "conn_ctrl_#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)
      path
    end
  end

  describe "enable banking" do
    test "the auth flow refuses a connector of another type", %{conn: conn, user: user} do
      config = create_strava(user.id)

      conn =
        post(conn, "/api/connectors/#{config.id}/enable_banking/auth_url", %{
          "redirect_url" => "https://app.test/cb"
        })

      assert %{"error" => "Not an Enable Banking connector"} = json_response(conn, 422)
    end

    test "the auth flow needs a redirect_url", %{conn: conn, user: user} do
      {:ok, config} =
        Connectors.create_connector_config(user.id, %{
          "connector_type" => "enable_banking",
          "name" => "Bank"
        })

      params = %{"redirect_url" => ""}
      conn = post(conn, "/api/connectors/#{config.id}/enable_banking/auth_url", params)
      assert %{"error" => "redirect_url is required"} = json_response(conn, 422)
    end

    test "the exchange needs a code", %{conn: conn, user: user} do
      {:ok, config} =
        Connectors.create_connector_config(user.id, %{
          "connector_type" => "enable_banking",
          "name" => "Bank"
        })

      conn = post(conn, "/api/connectors/#{config.id}/enable_banking/exchange", %{"code" => ""})
      assert %{"error" => "code is required"} = json_response(conn, 422)
    end

    test "the exchange refuses a connector of another type", %{conn: conn, user: user} do
      config = create_strava(user.id)

      conn =
        post(conn, "/api/connectors/#{config.id}/enable_banking/exchange", %{"code" => "abc"})

      assert %{"error" => "Not an Enable Banking connector"} = json_response(conn, 422)
    end
  end
end
