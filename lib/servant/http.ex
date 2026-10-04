defmodule Servant.HTTP do
  @moduledoc """
  Shared HTTP helpers for all connectors.

  TLS certificates are **verified by default** (`verify_peer` with the CA certificates of the OS).
  A known OTP 27 regression makes the handshake reject some certificates that
  are valid in all other respects, with a `key_usage_mismatch` error (for
  example data.gouv.fr, some CDN certs). The error occurs before the call to
  `verify_fun`, so a workaround for each request is not possible. For those
  specific hosts only, pass `verify: false` at the call site (for example
  `req_options(verify: false)`). Never pass it globally. As a result, the
  flows that carry secrets (Strava OAuth, RPC and explorers) keep the
  certificate verification.
  """

  @doc """
  Returns the default Req options. TLS peer verification is on by default.
  Pass `verify: false` to disable it for one call. The module doc tells when
  there is a good reason for that.
  """
  def req_options(extra \\ []) do
    {verify, extra} = Keyword.pop(extra, :verify, true)

    verify_opts =
      if verify do
        [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
      else
        [verify: :verify_none]
      end

    [
      receive_timeout: 30_000,
      connect_options: [transport_opts: verify_opts]
    ]
    |> Keyword.merge(Application.get_env(:servant, __MODULE__, []))
    |> Keyword.merge(extra)
  end

  @doc """
  Pauses between calls to a rate-limited third-party API, as a courtesy. The
  pause is disabled in tests (`config :servant, :connector_throttle, false`),
  so that the suites do not sleep.
  """
  def throttle(ms) do
    if Application.get_env(:servant, :connector_throttle, true), do: Process.sleep(ms)
    :ok
  end

  @doc """
  SSRF guard for the URLs that a user supplies (for example RSS and iCal
  feeds). Returns `:ok` only for an `http` or `https` URL with a host that
  resolves only to public IPs. If not, returns `{:error, :blocked_url}`.
  Blocks these ranges:

  - loopback
  - private
  - link-local (this includes the cloud metadata endpoint `169.254.169.254`)
  - unique-local

  Note: this is a best-effort guard at validation time. It gives no
  protection from DNS rebinding between this resolution and the request.
  """
  def ensure_public_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with true <- uri.scheme in ["http", "https"],
         host when is_binary(host) and host != "" <- uri.host,
         {:ok, addrs} <- resolve_host(host),
         false <- Enum.empty?(addrs),
         false <- Enum.any?(addrs, &private_ip?/1) do
      :ok
    else
      _ -> {:error, :blocked_url}
    end
  end

  def ensure_public_url(_), do: {:error, :blocked_url}

  defp resolve_host(host) do
    charlist = String.to_charlist(host)

    case getaddrs(charlist, :inet) ++ getaddrs(charlist, :inet6) do
      [] -> :error
      addrs -> {:ok, addrs}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      _ -> []
    end
  end

  # IPv4
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_ip?({0, _, _, _}), do: true
  # IPv6 loopback ::1 and unspecified ::
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv4-mapped IPv6 ::ffff:a.b.c.d: do the test again on the embedded v4.
  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private_ip?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  # IPv6 unique-local fc00::/7 and link-local fe80::/10
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp private_ip?(_), do: false
end
