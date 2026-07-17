defmodule ServantWeb.AiConfigControllerTest do
  use ServantWeb.ConnCase

  alias Servant.Accounts

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "GET returns the defaults with a nil key", %{conn: conn} do
    conn = get(conn, "/api/ai_config")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["enabled"] == false
    assert data["base_url"] == "http://localhost:11434/v1"
    assert data["api_key"] == nil
  end

  test "PUT updates the config and masks the key", %{conn: conn} do
    conn =
      put(conn, "/api/ai_config", %{
        "enabled" => true,
        "model" => "test-model",
        "api_key" => "sk-secret"
      })

    assert %{"data" => data} = json_response(conn, 200)
    assert data["enabled"] == true
    assert data["api_key"] == "***"
  end

  test "PUT with the mask keeps the stored key", %{conn: conn, user: user} do
    {:ok, _} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret", "model" => "m"})

    conn = put(conn, "/api/ai_config", %{"api_key" => "***", "model" => "m2"})
    assert json_response(conn, 200)

    user = Accounts.get_user!(user.id)
    assert Accounts.ai_config(user)["api_key"] == "sk-secret"
    assert Accounts.ai_config(user)["model"] == "m2"
  end

  test "PUT rejects enabling without a model", %{conn: conn} do
    conn = put(conn, "/api/ai_config", %{"enabled" => true})
    assert %{"error" => _} = json_response(conn, 422)
  end

  test "401 without auth" do
    conn = get(build_conn(), "/api/ai_config")
    assert json_response(conn, 401)
  end
end
