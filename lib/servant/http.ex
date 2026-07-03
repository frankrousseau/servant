defmodule Servant.HTTP do
  @moduledoc """
  Shared HTTP helpers for all connectors.

  TLS certificates are **verified by default** (`verify_peer` via CAStore).
  A known OTP 27 regression makes the handshake reject some otherwise-valid
  certificates with a `key_usage_mismatch` error (e.g. data.gouv.fr, some CDN
  certs); it happens before `verify_fun` is invoked, so it can't be worked
  around per-request. For those specific hosts only, pass `verify: false` at the
  call site (e.g. `req_options(verify: false)`) — never globally, so secret-
  bearing flows (Strava OAuth, RPC/explorers) keep certificate verification.
  """

  @doc """
  Returns default Req options. TLS peer verification is on by default; pass
  `verify: false` to disable it for a single call (see the module doc for when
  that's justified).
  """
  def req_options(extra \\ []) do
    {verify, extra} = Keyword.pop(extra, :verify, true)

    verify_opts =
      if verify do
        [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
      else
        [verify: :verify_none]
      end

    Keyword.merge(
      [
        receive_timeout: 30_000,
        connect_options: [transport_opts: verify_opts]
      ],
      extra
    )
  end

  @doc """
  SSRF guard for user-supplied URLs (RSS/iCal feeds, etc.). Returns `:ok` only
  for an `http`/`https` URL whose host resolves exclusively to public IPs;
  otherwise `{:error, :blocked_url}`. Blocks loopback, private, link-local
  (incl. the cloud metadata endpoint `169.254.169.254`) and unique-local ranges.

  Note: this is a best-effort check at validation time and does not defend
  against DNS rebinding between this resolution and the actual request.
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
  # IPv4-mapped IPv6 ::ffff:a.b.c.d — re-check the embedded v4
  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private_ip?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  # IPv6 unique-local fc00::/7 and link-local fe80::/10
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp private_ip?(_), do: false
end
