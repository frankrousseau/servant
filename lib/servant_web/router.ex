defmodule ServantWeb.Router do
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

  scope "/api", ServantWeb do
    pipe_through :api

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/logout", AuthController, :logout

    # Authenticated routes
    pipe_through :auth

    get "/auth/me", AuthController, :me
    put "/auth/profile", AuthController, :update_profile
    put "/auth/password", AuthController, :change_password
    post "/auth/avatar", AuthController, :upload_avatar

    get "/entries/kinds", EntryController, :kinds
    get "/entries/sources", EntryController, :sources
    get "/entries/stats", EntryController, :stats
    resources "/entries", EntryController, except: [:new, :edit]

    get "/notes/:id/backlinks", NotesController, :backlinks
    resources "/notes", NotesController, except: [:new, :edit]

    resources "/connectors", ConnectorController, except: [:new, :edit]
    post "/connectors/:id/start", ConnectorController, :start
    post "/connectors/:id/stop", ConnectorController, :stop
    post "/connectors/:id/sync", ConnectorController, :sync
    post "/connectors/:id/import", ConnectorController, :import_file
    get "/connectors/:id/logs", ConnectorController, :logs
    get "/connectors/schedules/:connector_type", ConnectorController, :schedules

    get "/apps", AppController, :index

    post "/uploads", UploadController, :create

    get "/export/entries", ExportController, :entries
    get "/export/entries.ics", ExportController, :ical
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
