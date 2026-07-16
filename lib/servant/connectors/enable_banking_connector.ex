defmodule Servant.Connectors.EnableBankingConnector do
  @moduledoc """
  Connector syncing bank transactions through Enable Banking, a licensed
  PSD2 aggregator covering most EU banks (La Banque Postale, CIC, ...).

  Setup happens in two steps. First the config: the Enable Banking
  application id and its RSA private key (every request is authenticated
  with a short-lived RS256 JWT signed here, no extra dependency). Then the
  consent: the connector page asks for an authorization URL (`auth_url/3`),
  the user approves at their bank and lands back on the SPA callback with a
  code that `exchange_code/2` turns into a session (id, accounts, expiry)
  persisted into the config. PSD2 consents expire after 90-180 days; syncs
  then fail with a reconnect message until the user re-consents.

  Sync walks each account's transactions since a per-account booking-date
  cursor, refetching a small overlap window; the entries upsert dedups on
  `external_id`.
  """

  use Servant.Connectors.Connector

  require Logger

  @api_base "https://api.enablebanking.com"
  @jwt_ttl 3600
  # Refetch window behind the cursor: banks book transactions late.
  @overlap_days 7
  # Requested consent length, capped by the bank's own maximum.
  @consent_days 180

  @impl true
  def id, do: "enable_banking"

  @impl true
  def name, do: "Open Banking (Enable Banking)"

  @impl true
  def required_credentials, do: [:application_id, :private_key]

  @impl true
  def kind, do: "bank_tx"

  @impl true
  def init(_credentials, config) do
    application_id = config_value(config, "application_id")
    private_key = config_value(config, "private_key")

    cond do
      is_nil(application_id) or application_id == "" ->
        {:error, "application_id is required"}

      is_nil(private_key) or private_key == "" ->
        {:error, "private_key is required"}

      decode_private_key(private_key) == :error ->
        {:error, "private_key is not a valid PEM RSA key"}

      true ->
        {:ok,
         %{
           application_id: application_id,
           private_key: private_key,
           bank_name: config_value(config, "bank_name"),
           country: config_value(config, "country", "FR"),
           session_id: config_value(config, "session_id"),
           accounts: config_value(config, "accounts", []),
           valid_until: config_value(config, "valid_until"),
           cursors: config_value(config, "cursors", %{})
         }}
    end
  end

  @impl true
  def persisted_config(state) do
    %{"cursors" => state.cursors}
  end

  @impl true
  def sync(state) do
    cond do
      state.session_id in [nil, ""] ->
        {:error, "Not connected to the bank yet: use Connect on the connector page", state}

      consent_expired?(state.valid_until) ->
        {:error, "Bank consent expired: reconnect from the connector page", state}

      true ->
        sync_accounts(state)
    end
  end

  defp sync_accounts(state) do
    {entries, cursors, errors} =
      Enum.reduce(state.accounts, {[], state.cursors, []}, fn account, {acc, cursors, errors} ->
        uid = account["uid"]
        label = account_label(account)
        cursor = cursors[uid]

        case fetch_transactions(state, uid, date_from(cursor), nil, []) do
          {:ok, transactions} ->
            new_cursor = latest_booking_date(transactions) || cursor

            {acc ++ Enum.map(transactions, &build_entry(&1, uid, label)),
             Map.put(cursors, uid, new_cursor), errors}

          {:error, reason} ->
            {acc, cursors, [reason | errors]}
        end
      end)

    case {entries, errors} do
      {[], [reason | _]} ->
        {:error, reason, state}

      {_, []} ->
        {:ok, entries, %{state | cursors: cursors}}

      {_, errs} ->
        # Some accounts synced, others failed (e.g. a partially revoked consent).
        # The worker marks the sync "completed" and clears config.error on {:ok},
        # so without this the amputated accounts would be silently invisible.
        Logger.error(
          "enable_banking: #{length(errs)} account(s) failed to sync: #{Enum.join(errs, "; ")}"
        )

        {:ok, entries, %{state | cursors: cursors}}
    end
  end

  defp consent_expired?(nil), do: false

  defp consent_expired?(valid_until) do
    case DateTime.from_iso8601(valid_until) do
      {:ok, dt, _offset} -> DateTime.compare(DateTime.utc_now(), dt) == :gt
      _ -> false
    end
  end

  defp date_from(nil), do: nil

  defp date_from(cursor) do
    case Date.from_iso8601(cursor) do
      {:ok, date} -> date |> Date.add(-@overlap_days) |> Date.to_iso8601()
      _ -> nil
    end
  end

  defp account_label(account) do
    account["name"] || get_in(account, ["account_id", "iban"]) || "Bank account"
  end

  # --- Consent flow (called by the connector controller, not the worker) ---

  @doc """
  Builds the bank authorization URL for the consent flow. `state_param` is
  echoed back on the redirect (the SPA passes the connector config id).
  """
  def auth_url(config, redirect_url, state_param) do
    with {:ok, state} <- init(%{}, config),
         :ok <- require_bank(state),
         {:ok, aspsp} <- find_aspsp(state) do
      valid_until =
        DateTime.utc_now()
        |> DateTime.add(consent_seconds(aspsp), :second)
        |> DateTime.to_iso8601()

      body = %{
        "aspsp" => %{"name" => aspsp["name"], "country" => state.country},
        "access" => %{
          "valid_until" => valid_until,
          "balances" => true,
          "transactions" => true
        },
        "state" => state_param,
        "redirect_url" => redirect_url,
        "psu_type" => "personal"
      }

      case api_post(state, "/auth", body) do
        {:ok, %{"url" => url}} -> {:ok, url}
        {:ok, _other} -> {:error, "Enable Banking returned no authorization URL"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Exchanges the authorization code for a session. Returns the config fields
  to persist (session id, accounts, consent expiry, reset cursors).
  """
  def exchange_code(config, code) do
    with {:ok, state} <- init(%{}, config),
         {:ok, session} <- api_post(state, "/sessions", %{"code" => code}) do
      accounts =
        session
        |> Map.get("accounts", [])
        |> Enum.map(
          &%{
            "uid" => &1["uid"],
            "name" => &1["name"],
            "account_id" => &1["account_id"],
            "currency" => &1["currency"]
          }
        )

      {:ok,
       %{
         "session_id" => session["session_id"],
         "accounts" => accounts,
         "valid_until" => get_in(session, ["access", "valid_until"]),
         "cursors" => %{}
       }}
    end
  end

  defp require_bank(%{bank_name: bank_name}) do
    if bank_name in [nil, ""] do
      {:error, "bank_name is required (the bank's name as listed by Enable Banking)"}
    else
      :ok
    end
  end

  defp find_aspsp(state) do
    case api_get(state, "/aspsps", country: state.country) do
      {:ok, %{"aspsps" => aspsps}} ->
        target = String.downcase(state.bank_name)

        case Enum.find(aspsps, &(String.downcase(&1["name"] || "") == target)) do
          nil ->
            close =
              aspsps
              |> Enum.map(& &1["name"])
              |> Enum.filter(&String.contains?(String.downcase(&1 || ""), target))
              |> Enum.take(5)

            hint = if close == [], do: "", else: "; close matches: #{Enum.join(close, ", ")}"
            {:error, "Bank \"#{state.bank_name}\" not found in #{state.country}#{hint}"}

          aspsp ->
            {:ok, aspsp}
        end

      {:ok, _other} ->
        {:error, "Enable Banking returned an unexpected bank list"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consent_seconds(aspsp) do
    max = aspsp["maximum_consent_validity"] || @consent_days * 86_400
    min(max, @consent_days * 86_400)
  end

  # --- Transactions ---

  defp fetch_transactions(state, account_uid, date_from, continuation_key, acc) do
    params =
      [transaction_status: "BOOK"] ++
        if(date_from, do: [date_from: date_from], else: []) ++
        if(continuation_key, do: [continuation_key: continuation_key], else: [])

    case api_get(state, "/accounts/#{account_uid}/transactions", params) do
      {:ok, %{"transactions" => transactions} = body} ->
        all = acc ++ transactions

        case body["continuation_key"] do
          key when is_binary(key) and key != "" ->
            fetch_transactions(state, account_uid, date_from, key, all)

          _ ->
            {:ok, all}
        end

      {:ok, _other} ->
        {:error, "Enable Banking returned an unexpected transactions payload"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_booking_date(transactions) do
    transactions
    |> Enum.map(& &1["booking_date"])
    |> Enum.filter(&is_binary/1)
    |> Enum.max(fn -> nil end)
  end

  # --- Entry building ---

  @doc false
  def build_entry(tx, account_uid, account_label) do
    amount = parse_amount(get_in(tx, ["transaction_amount", "amount"]))
    signed = if tx["credit_debit_indicator"] == "DBIT", do: -abs(amount), else: abs(amount)
    direction = if signed < 0, do: "sent", else: "received"
    currency = get_in(tx, ["transaction_amount", "currency"]) || "EUR"

    counterparty =
      if direction == "sent",
        do: get_in(tx, ["creditor", "name"]),
        else: get_in(tx, ["debtor", "name"])

    description =
      case Enum.filter(tx["remittance_information"] || [], &(String.trim(&1 || "") != "")) do
        [] -> counterparty || "Bank transaction"
        parts -> Enum.join(parts, " - ")
      end

    date = tx["booking_date"] || tx["transaction_date"] || tx["value_date"]

    occurred_at =
      case Date.from_iso8601(date || "") do
        {:ok, d} -> DateTime.new!(d, ~T[12:00:00], "Etc/UTC")
        _ -> DateTime.truncate(DateTime.utc_now(), :second)
      end

    verb = if direction == "sent", do: "Paid", else: "Received"

    %{
      "kind" => "bank_tx",
      "source" => "enable_banking",
      "external_id" => external_id(tx, account_uid),
      "title" => "#{verb} #{format_amount(abs(signed))} #{currency} - #{description}",
      "occurred_at" => occurred_at,
      "data" => %{
        "description" => description,
        "amount" => signed,
        "abs_amount" => abs(signed),
        "currency" => currency,
        "direction" => direction,
        "balance" => parse_optional_amount(get_in(tx, ["balance_after_transaction", "amount"])),
        "account" => account_label,
        "counterparty" => counterparty
      },
      "metadata" => %{
        "import_source" => "enable_banking",
        "entry_reference" => tx["entry_reference"]
      }
    }
  end

  # Not every bank sends transaction ids, and references are only unique per
  # account, so the account uid is always part of the identity.
  defp external_id(tx, account_uid) do
    reference =
      tx["entry_reference"] || tx["transaction_id"] ||
        "#{tx["booking_date"]}|#{get_in(tx, ["transaction_amount", "amount"])}|#{Enum.join(tx["remittance_information"] || [], "|")}"

    :crypto.hash(:sha256, "#{account_uid}|#{reference}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  defp parse_amount(nil), do: 0.0

  defp parse_amount(str) when is_binary(str) do
    case Float.parse(str) do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  defp parse_optional_amount(nil), do: nil
  defp parse_optional_amount(str), do: parse_amount(str)

  defp format_amount(amount) when is_float(amount) do
    :erlang.float_to_binary(amount, decimals: 2)
  end

  defp format_amount(amount), do: to_string(amount)

  # --- HTTP with JWT auth ---

  defp api_get(state, path, params) do
    request(state, :get, path, params: params)
  end

  defp api_post(state, path, body) do
    request(state, :post, path, json: body)
  end

  defp request(state, method, path, opts) do
    headers = [{"authorization", "Bearer #{jwt(state)}"}]
    opts = Servant.HTTP.req_options([headers: headers] ++ opts)

    result =
      case method do
        :get -> Req.get(@api_base <> path, opts)
        :post -> Req.post(@api_base <> path, opts)
      end

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "Unauthorized: check the application id and private key"}

      {:ok, %Req.Response{status: status}} when status in [403, 410] ->
        {:error, "Bank consent expired or revoked: reconnect from the connector page"}

      {:ok, %Req.Response{status: 429}} ->
        {:error, "Enable Banking rate limit exceeded, try again later"}

      {:ok, %Req.Response{status: status, body: body}} ->
        detail = if is_map(body), do: body["message"] || body["detail"], else: nil
        {:error, "Enable Banking API error #{status}#{if detail, do: ": #{detail}", else: ""}"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  @doc false
  def jwt(state) do
    now = System.os_time(:second)

    header = %{"typ" => "JWT", "alg" => "RS256", "kid" => state.application_id}

    payload = %{
      "iss" => "enablebanking.com",
      "aud" => "api.enablebanking.com",
      "iat" => now,
      "exp" => now + @jwt_ttl
    }

    signing_input = b64url(Jason.encode!(header)) <> "." <> b64url(Jason.encode!(payload))
    {:ok, key} = decode_private_key(state.private_key)
    signing_input <> "." <> b64url(:public_key.sign(signing_input, :sha256, key))
  end

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  defp decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> :error
    end
  rescue
    _ -> :error
  end
end
