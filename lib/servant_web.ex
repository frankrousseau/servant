defmodule ServantWeb do
  @moduledoc """
  The entrypoint that defines your web interface, such
  as controllers, components, channels and other items.

  Use it in your application as follows:

      use ServantWeb, :controller
      use ServantWeb, :html

  Each controller, component and other item runs the
  definitions below. Keep them short and clean. Include
  only imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Define additional modules and import
  those modules here.
  """

  # `models` holds the face-detection weights (frontend/public/models).
  # List here each other file of frontend/public that the SPA references
  # (logo.svg on the public share page, strava-logo.png). If a file is not in
  # the list, the request goes to the SPA fallback and the image renders as
  # broken.
  # "swagger" holds the SwaggerUI assets that the frontend build copies in.
  # The /api/docs page (ServantWeb.DocsController) gets them.
  def static_paths,
    do:
      ~w(assets fonts images models swagger favicon.ico favicon.svg logo.svg strava-logo.png robots.txt index.html)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import the common connection and controller functions for use in pipelines.
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
      import ServantWeb.ChangesetHelpers, only: [format_errors: 1]

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ServantWeb.Endpoint,
        router: ServantWeb.Router,
        statics: ServantWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the applicable controller, live_view or other definition.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
