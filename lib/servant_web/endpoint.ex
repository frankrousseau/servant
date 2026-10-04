defmodule ServantWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :servant

  # The cookie stores the session, and the session is signed.
  # As a result, a client can read its contents but cannot tamper with them.
  # Set :encryption_salt to also encrypt it.
  @session_options [
    store: :cookie,
    key: "_servant_key",
    signing_salt: "ZbJqQ+IZ",
    same_site: "Lax"
  ]

  # The LiveView socket exists only for the dev-only LiveDashboard. This is an
  # API-only app, and it has no other LiveView.
  if Application.compile_env(:servant, :dev_routes) do
    socket "/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [session: @session_options]],
      longpoll: [connect_info: [session: @session_options]]
  end

  socket "/socket", ServantWeb.UserSocket,
    websocket: true,
    longpoll: false

  # Serve at "/" the static files from the "priv/static" directory.
  #
  # When code reloading is off (for example, in production),
  # the `gzip` option is on. It serves the compressed
  # static files that `phx.digest` generates.
  plug Plug.Static,
    at: "/",
    from: :servant,
    gzip: not code_reloading?,
    only: ServantWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # An authenticated controller in the router (ServantWeb.FilesController) serves
  # the user files (/files, /uploads). They are never unauthenticated statics.

  # To turn on code reloading explicitly, use the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :servant
  end

  if Application.compile_env(:servant, :dev_routes) do
    plug Phoenix.LiveDashboard.RequestLogger,
      param_key: "request_logger",
      cookie_key: "request_logger"
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Behind the documented nginx deployment, each request arrives from
  # 127.0.0.1. RemoteIp restores the real client address from
  # X-Forwarded-For. By default, loopback and private peers count as
  # proxies. RemoteIp ignores the header when the peer is a direct public
  # client. As a result, the per-IP auth throttle and the access log see
  # the real clients.
  plug RemoteIp
  plug ServantWeb.Plugs.AccessLog

  plug Plug.Parsers,
    # JSON-only API (uploads are multipart). There is no :urlencoded parser on
    # purpose. A cross-site HTML form posts application/x-www-form-urlencoded as
    # a CORS "simple" request (no preflight). With the parser, such a form can
    # reach POST /api/auth/login and set the SameSite=Lax cookie (login CSRF).
    # Without the parser, those bodies stay unparsed and the endpoints return 422.
    # Cap JSON at 10MB. Multipart gets its own budget, a little above the 1GB
    # upload limit (UploadController enforces that limit).
    parsers: [:json, {:multipart, length: 1_100_000_000}],
    pass: ["*/*"],
    length: 10_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ServantWeb.Router
end
