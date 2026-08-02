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
end
