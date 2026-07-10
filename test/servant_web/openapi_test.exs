defmodule ServantWeb.OpenApiTest do
  use ServantWeb.ConnCase, async: true

  @verbs ~w(get put post delete options head patch trace)a

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

  # Known limitation: the check is path-keyed, so a second /api route reusing
  # an already-documented action is not independently verified.
  test "every /api route is documented in the spec" do
    spec = ServantWeb.ApiSpec.spec()

    documented =
      for {path, item} <- spec.paths,
          verb <- @verbs,
          match?(%OpenApiSpex.Operation{}, Map.get(item, verb)),
          into: MapSet.new(),
          do: {verb, path}

    expected =
      for r <- ServantWeb.Router.__routes__(),
          String.starts_with?(r.path, "/api"),
          r.path not in ["/api/openapi.json", "/api/docs"],
          into: MapSet.new(),
          do: {r.verb, to_openapi_path(r.path)}

    assert MapSet.to_list(MapSet.difference(expected, documented)) == []
  end

  test "the spec serializes to JSON" do
    assert {:ok, _json} = Jason.encode(OpenApiSpex.OpenApi.to_map(ServantWeb.ApiSpec.spec()))
  end

  defp to_openapi_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> name -> "{#{name}}"
      "*" <> name -> "{#{name}}"
      seg -> seg
    end)
  end
end
