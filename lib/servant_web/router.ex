defmodule ServantWeb.Router do
  @moduledoc false

  use ServantWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug ServantWeb.Auth
  end

  pipeline :file_auth do
    plug ServantWeb.Plugs.FileAuth
  end

  pipeline :admin do
    plug ServantWeb.Plugs.RequireAdmin
  end

  pipeline :session_only do
    plug ServantWeb.Plugs.SessionOnly
  end

  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: ServantWeb.ApiSpec
  end

  scope "/api" do
    pipe_through :openapi

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  scope "/api", ServantWeb do
    pipe_through :api

    get "/auth/config", AuthController, :config
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/totp/verify", AuthController, :totp_verify

    scope "/" do
      pipe_through :auth

      # Reachable by scoped API tokens; scope checks live in the controllers.
      get "/entries/kinds", EntryController, :kinds
      get "/entries/sources", EntryController, :sources
      get "/entries/stats", EntryController, :stats
      get "/entries/stats/daily", EntryController, :daily_stats
      get "/entries/aggregate", EntryController, :aggregate
      resources "/entries", EntryController, except: [:new, :edit]

      get "/notes/mentioning/:entry_id", NotesController, :mentioning
      get "/notes/:id/backlinks", NotesController, :backlinks
      resources "/notes", NotesController, except: [:new, :edit]

      get "/apps", AppController, :index

      post "/uploads", UploadController, :create

      get "/export/entries", ExportController, :entries
      get "/export/entries.ics", ExportController, :ical

      scope "/" do
        pipe_through :session_only

        post "/auth/logout", AuthController, :logout
        get "/auth/me", AuthController, :me
        post "/auth/totp/setup", AuthController, :totp_setup
        post "/auth/totp/confirm", AuthController, :totp_confirm
        delete "/auth/totp", AuthController, :totp_disable
        put "/auth/profile", AuthController, :update_profile
        put "/auth/password", AuthController, :change_password
        post "/auth/avatar", AuthController, :upload_avatar

        resources "/tokens", ApiTokenController, only: [:index, :create, :delete]

        post "/apps", AppController, :create
        post "/apps/:id/update", AppController, :update
        delete "/apps/:id", AppController, :delete

        post "/entries/backfill_media", EntryController, :backfill_media

        resources "/connectors", ConnectorController, except: [:new, :edit]
        post "/connectors/:id/start", ConnectorController, :start
        post "/connectors/:id/stop", ConnectorController, :stop
        post "/connectors/:id/sync", ConnectorController, :sync
        post "/connectors/:id/import", ConnectorController, :import_file
        get "/connectors/:id/logs", ConnectorController, :logs
        get "/connectors/schedules/:connector_type", ConnectorController, :schedules

        # Operator-only: server-wide stats + all users' access/error logs.
        scope "/" do
          pipe_through :admin

          get "/audit/system", AuditController, :system
          get "/audit/logs", AuditController, :logs
        end
      end
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:servant, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ServantWeb.Telemetry
    end
  end

  # Authenticated, per-user file serving (must come before the SPA catch-all).
  scope "/", ServantWeb do
    pipe_through :file_auth

    get "/files/*path", FilesController, :show
    get "/uploads/*path", FilesController, :show
  end

  # SPA catch-all: must be after /api and /dev routes
  scope "/", ServantWeb do
    get "/*path", SpaController, :index
  end
end
