defmodule ServantWeb.DocsController do
  @moduledoc """
  SwaggerUI page for the OpenAPI spec, served at /api/docs.

  Replaces `OpenApiSpex.Plug.SwaggerUI`, whose page pulls its JS and CSS from a
  CDN: a self-hosted instance is expected to work without internet access. The
  assets are copied out of `swagger-ui-dist` into `priv/static/swagger` by the
  frontend build, so a release that ships the SPA also ships them.
  """

  use ServantWeb, :controller

  @page """
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Servant API</title>
      <link rel="stylesheet" href="/swagger/swagger-ui.css" />
      <style>body { margin: 0 }</style>
    </head>
    <body>
      <div id="swagger-ui"></div>
      <script src="/swagger/swagger-ui-bundle.js"></script>
      <script src="/swagger/swagger-ui-standalone-preset.js"></script>
      <script>
        window.onload = function () {
          SwaggerUIBundle({
            url: '/api/openapi.json',
            dom_id: '#swagger-ui',
            deepLinking: true,
            presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
            layout: 'BaseLayout'
          })
        }
      </script>
    </body>
  </html>
  """

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, @page)
  end
end
