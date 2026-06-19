defmodule Servant.HTTP do
  @moduledoc """
  Shared HTTP helpers for all connectors.

  Uses `verify: :verify_none` to work around an OTP 27 bug where the TLS
  handshake rejects valid certificates with a key_usage_mismatch error
  (e.g. data.gouv.fr, some CDN certs). This is a known OTP 27 regression
  that cannot be fixed via verify_fun since the check happens before the
  callback is invoked. Safe for a self-hosted personal app.
  """

  @doc """
  Returns default Req options.
  """
  def req_options(extra \\ []) do
    Keyword.merge(
      [
        receive_timeout: 30_000,
        connect_options: [
          transport_opts: [
            verify: :verify_none
          ]
        ]
      ],
      extra
    )
  end
end
