defmodule ServantWeb.ApiSpec do
  @moduledoc "OpenAPI specification, served at /api/openapi.json (SwaggerUI at /api/docs)."

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApi
  def spec do
    spec = %OpenApi{
      info: %Info{
        title: "Servant API",
        description: """
        Self-hosted personal data hub.

        Authentication: `Authorization: Bearer <token>`. Two credential types:
        - session tokens (used by the SPA, also carried by an HttpOnly cookie): full access
        - API tokens (`srv_` prefixed, created in Settings): restricted by scopes of the
          form `app:<domain>:<read|write>` (notes, checklists, calendar, contacts, photos,
          files, finance, trackers) plus the `data:<read|write>` wildcard. `write` implies
          `read`. Scope failures return 403 with the required scope.
        """,
        version: to_string(Application.spec(:servant, :vsn) || "dev")
      },
      servers: [Server.from_endpoint(ServantWeb.Endpoint)],
      paths: Paths.from_router(ServantWeb.Router),
      components: %Components{
        securitySchemes: %{"bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"bearerAuth" => []}]
    }

    OpenApiSpex.resolve_schema_modules(spec)
  end
end
