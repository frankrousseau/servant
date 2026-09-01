defmodule Servant.Connectors.OvhConnector do
  @moduledoc """
  OVH invoice connector on the official signed API: no browser, no password,
  no 2FA at run time (unlike the Playwright provider it replaces).

  Credentials are the application key / application secret / consumer key
  triple created in one page at https://eu.api.ovh.com/createToken with the
  rights `GET /me/bill` and `GET /me/bill/*` (validity "Unlimited"). Every
  request carries OVH's signature: sha1 over
  `secret+consumer+method+url+body+timestamp`, with the timestamp corrected
  by the server clock from `/auth/time`.
  """

  use Servant.Connectors.Connector

  @default_endpoint "https://eu.api.ovh.com/1.0"
  @max_bills 50

  @impl true
  def id, do: "ovh"

  @impl true
  def name, do: "OVH"

  @impl true
  def required_credentials, do: [:application_key, :application_secret, :consumer_key]

  @impl true
  def kind, do: "invoice"

  @impl true
  def supported_schedules, do: ~w(on_demand every_day every_week)

  @impl true
  def default_schedule, do: "every_day"

  @impl true
  def init(_credentials, config) do
    app_key = trimmed(config, "application_key")
    app_secret = trimmed(config, "application_secret")
    consumer_key = trimmed(config, "consumer_key")

    cond do
      app_key == "" ->
        {:error, :missing_application_key}

      app_secret == "" ->
        {:error, :missing_application_secret}

      consumer_key == "" ->
        {:error, :missing_consumer_key}

      true ->
        endpoint =
          case trimmed(config, "endpoint") do
            "" -> @default_endpoint
            url -> String.trim_trailing(url, "/")
          end

        {:ok,
         %{
           app_key: app_key,
           app_secret: app_secret,
           consumer_key: consumer_key,
           endpoint: endpoint
         }}
    end
  end

  @impl true
  def sync(state) do
    with {:ok, drift} <- time_drift(state),
         {:ok, ids} <- list_bill_ids(state, drift),
         {:ok, bills} <- fetch_bills(state, ids, drift) do
      {:ok, Enum.map(bills, &build_entry/1), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc false
  def signature(app_secret, consumer_key, method, url, body, timestamp) do
    payload = Enum.join([app_secret, consumer_key, method, url, body, timestamp], "+")
    "$1$" <> Base.encode16(:crypto.hash(:sha, payload), case: :lower)
  end

  @doc false
  def build_entry(bill) do
    price = bill["priceWithTax"] || %{}
    amount = price["value"] || 0
    currency = price["currencyCode"] || "EUR"
    occurred_at = parse_datetime(bill["date"])

    month_label =
      case occurred_at do
        %DateTime{} = dt -> Calendar.strftime(dt, "%B %Y")
        _ -> to_string(bill["date"] || "")
      end

    label = price["text"] || "#{amount} #{currency}"

    %{
      "kind" => "invoice",
      "source" => "ovh",
      "external_id" => "ovh-#{bill["billId"]}",
      "title" => "OVH - #{label} (#{month_label})",
      "occurred_at" => occurred_at || DateTime.truncate(DateTime.utc_now(), :second),
      "data" => %{
        "provider" => "ovh",
        "amount" => to_string(amount),
        "currency" => currency,
        "status" => "paid",
        "url" => bill["pdfUrl"] || bill["url"]
      },
      "metadata" => %{}
    }
  end

  defp trimmed(config, key) do
    String.trim(to_string(config_value(config, key, "")))
  end

  # The signature covers a timestamp OVH checks against its own clock, so a
  # drifting server clock would 403 every call; sync on theirs once per run.
  defp time_drift(state) do
    case Req.get(state.endpoint <> "/auth/time", Servant.HTTP.req_options()) do
      {:ok, %Req.Response{status: 200, body: server_time}} when is_integer(server_time) ->
        {:ok, server_time - System.os_time(:second)}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Integer.parse(String.trim(body)) do
          {server_time, _rest} -> {:ok, server_time - System.os_time(:second)}
          :error -> {:error, "OVH /auth/time returned an unreadable clock: #{inspect(body)}"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "OVH /auth/time returned HTTP #{status}"}

      {:error, error} ->
        {:error, "OVH API unreachable: #{Exception.message(error)}"}
    end
  end

  defp list_bill_ids(state, drift) do
    case get_signed(state, "/me/bill", drift) do
      {:ok, ids} when is_list(ids) -> {:ok, ids |> Enum.sort() |> Enum.take(-@max_bills)}
      {:ok, other} -> {:error, "unexpected /me/bill payload: #{inspect(other)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Entry dedup on external_id makes refetching known bills harmless, so no
  # cursor; the last @max_bills cover any realistic gap between syncs.
  defp fetch_bills(state, ids, drift) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case get_signed(state, "/me/bill/" <> URI.encode(to_string(id)), drift) do
        {:ok, bill} -> {:cont, {:ok, [bill | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp get_signed(state, path, drift) do
    url = state.endpoint <> path
    timestamp = System.os_time(:second) + drift

    headers = [
      {"x-ovh-application", state.app_key},
      {"x-ovh-consumer", state.consumer_key},
      {"x-ovh-timestamp", Integer.to_string(timestamp)},
      {"x-ovh-signature",
       signature(state.app_secret, state.consumer_key, "GET", url, "", timestamp)}
    ]

    case Req.get(url, Servant.HTTP.req_options(headers: headers)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "OVH API #{path} returned HTTP #{status}: #{error_message(body)}"}

      {:error, error} ->
        {:error, "OVH API unreachable: #{Exception.message(error)}"}
    end
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(body), do: body |> inspect() |> String.slice(0, 200)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      _ ->
        case Date.from_iso8601(String.slice(value, 0, 10)) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp parse_datetime(_value), do: nil
end
