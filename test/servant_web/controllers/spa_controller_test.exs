defmodule ServantWeb.SpaControllerTest do
  use ServantWeb.ConnCase

  @index_path Path.join(:code.priv_dir(:servant), "static/index.html")

  setup do
    created =
      if File.exists?(@index_path) do
        false
      else
        File.mkdir_p!(Path.dirname(@index_path))

        File.write!(
          @index_path,
          "<!doctype html><html><body><div id=\"app\"></div></body></html>"
        )

        true
      end

    on_exit(fn -> if created, do: File.rm(@index_path) end)
    :ok
  end

  test "serves the SPA with a strict CSP and security headers", %{conn: conn} do
    conn = get(conn, "/")
    assert response(conn, 200)

    csp = conn |> get_resp_header("content-security-policy") |> List.first()
    assert csp =~ "default-src 'self'"
    assert csp =~ "script-src 'self'"
    assert csp =~ "object-src 'none'"
    # scripts must NOT be allowed inline / eval
    refute csp =~ "'unsafe-eval'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
  end

  # A public file missing from static_paths falls through to the SPA fallback
  # in production (Vite serves it in dev, so nothing shows until deployed).
  test "every frontend/public file the SPA references is served" do
    frontend = Path.expand("../../../frontend", __DIR__)

    sources =
      [
        Path.join(frontend, "index.html")
        | Path.wildcard(Path.join(frontend, "src/**/*.{vue,ts}"))
      ]
      |> Enum.map_join("\n", &File.read!/1)

    missing =
      for name <- File.ls!(Path.join(frontend, "public")),
          String.contains?(sources, "/" <> name),
          name not in ServantWeb.static_paths(),
          do: name

    assert missing == []
  end
end
