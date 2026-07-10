defmodule ServantWeb.OpenApiTest do
  use ServantWeb.ConnCase, async: true

  test "serves a valid JSON spec without auth", %{conn: conn} do
    spec = json_response(get(conn, "/api/openapi.json"), 200)
    assert spec["openapi"] =~ "3."
    assert spec["info"]["title"] == "Servant API"
    assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
  end

  test "serves SwaggerUI", %{conn: conn} do
    conn = get(conn, "/api/docs")
    assert response(conn, 200) =~ "swagger"
  end
end
