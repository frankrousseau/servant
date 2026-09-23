defmodule ServantWeb.Router do
  @moduledoc false

  use ServantWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    # Documented operations validate their own request against the spec
    # (see ServantWeb.Api.Validated); the spec has to be in the conn for that.
    plug OpenApiSpex.Plug.PutApiSpec, module: ServantWeb.ApiSpec
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

  pipeline :dav do
    plug ServantWeb.Plugs.DavAuth
  end

  scope "/api" do
    pipe_through :openapi

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", ServantWeb.DocsController, :index
  end

  scope "/api", ServantWeb do
    pipe_through :api

    get "/auth/config", AuthController, :config
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/totp/verify", AuthController, :totp_verify

    # Public photo feeds: the share token in the URL is the credential.
    get "/shares/:token", ShareController, :show

    scope "/" do
      pipe_through :auth

      # Reachable by scoped API tokens; scope checks live in the controllers.
      get "/entries/kinds", EntryController, :kinds
      get "/entries/sources", EntryController, :sources
      get "/entries/stats", EntryController, :stats
      get "/entries/stats/daily", EntryController, :daily_stats
      get "/entries/aggregate", EntryController, :aggregate
      delete "/entries", EntryController, :delete_matching
      resources "/entries", EntryController, except: [:new, :edit]

      post "/contacts/merge", ContactsController, :merge

      get "/notes/mentioning/:entry_id", NotesController, :mentioning
      get "/notes/:id/backlinks", NotesController, :backlinks
      resources "/notes", NotesController, except: [:new, :edit]

      get "/agent_memory", AgentMemoryController, :index
      post "/agent_memory", AgentMemoryController, :upsert
      delete "/agent_memory", AgentMemoryController, :delete

      get "/apps", AppController, :index
      get "/version", VersionController, :show

      post "/uploads", UploadController, :create
      post "/client_errors", ClientErrorController, :create

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
        resources "/photo_shares", PhotoShareController, only: [:index, :create, :delete]

        post "/apps", AppController, :create
        post "/apps/:id/update", AppController, :update
        delete "/apps/:id", AppController, :delete

        post "/apps/generate", AppController, :generate
        get "/agents/runs", AgentController, :runs
        get "/agents/runs/:id", AgentController, :show_run
        post "/agents/:id/run", AgentController, :run
        post "/agents/draft_recipe", AgentController, :draft_recipe
        resources "/agents", AgentController, except: [:new, :edit]
        post "/apps/:id/modify", AppController, :modify
        post "/apps/:id/restore", AppController, :restore

        get "/ai_config", AiConfigController, :show
        put "/ai_config", AiConfigController, :update

        post "/entries/backfill_media", EntryController, :backfill_media
        post "/entries/:id/rotate_photo", EntryController, :rotate_photo

        resources "/connectors", ConnectorController, except: [:new, :edit]
        post "/connectors/:id/start", ConnectorController, :start
        post "/connectors/:id/stop", ConnectorController, :stop
        post "/connectors/:id/sync", ConnectorController, :sync
        post "/connectors/:id/import", ConnectorController, :import_file
        post "/connectors/:id/enable_banking/auth_url", ConnectorController, :eb_auth_url
        post "/connectors/:id/enable_banking/exchange", ConnectorController, :eb_exchange
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

  # CalDAV/CardDAV endpoint for phone sync (HTTP Basic, token as password).
  scope "/", ServantWeb do
    match :*, "/.well-known/caldav", DavController, :well_known
    match :*, "/.well-known/carddav", DavController, :well_known
  end

  scope "/dav", ServantWeb do
    pipe_through :dav

    match :*, "/*path", DavController, :dav
  end

  # Authenticated, per-user file serving (must come before the SPA catch-all).
  scope "/", ServantWeb do
    pipe_through :file_auth

    get "/files/*path", FilesController, :show
    get "/uploads/*path", FilesController, :show
  end

  # Files of a public photo feed (no auth: the share token is the credential;
  # only the files of photos currently in the feed resolve). The page itself,
  # /share/:token, is the SPA.
  scope "/", ServantWeb do
    get "/share/:token/files/*path", ShareFileController, :show
  end

  # SPA catch-all: must be after /api and /dev routes
  scope "/", ServantWeb do
    get "/*path", SpaController, :index
  end
end
