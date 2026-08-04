defmodule ServantWeb.SpaController do
  @moduledoc "Serves the built SPA with security headers (catch-all route)."

  use ServantWeb, :controller

  # `script-src 'self'` blocks injected/inline scripts (the payoff of removing
  # inline handlers in). `style-src` keeps 'unsafe-inline' because the
  # apps and Vue set inline style attributes; that's a far smaller risk than
  # inline scripts. The HEIC-to-JPEG converter (heic-to) runs libheif in a
  # blob: worker, hence `worker-src blob:`; `wasm-unsafe-eval` permits wasm
  # compilation only (never JS eval) and engines differ on requiring it.
  # Only applies in production (Vite serves index.html in dev).
  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self' 'wasm-unsafe-eval'",
           "worker-src 'self' blob:",
           "style-src 'self' 'unsafe-inline'",
           "img-src 'self' data:",
           "font-src 'self'",
           # Crypto spot prices (finance Cryptos tab): CoinGecko for majors,
           # DexScreener search for everything else. Both are public, no key.
           "connect-src 'self' https://api.coingecko.com https://api.dexscreener.com",
           "object-src 'none'",
           "base-uri 'self'",
           "frame-ancestors 'self'"
         ],
         "; "
       )

  def index(conn, _params) do
    index_path = Path.join(:code.priv_dir(:servant), "static/index.html")

    if File.exists?(index_path) do
      conn
      |> put_security_headers()
      |> put_resp_content_type("text/html")
      |> send_file(200, index_path)
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "SPA not built. Run npm run build in frontend/"})
    end
  end

  defp put_security_headers(conn) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("x-frame-options", "DENY")
  end
end
