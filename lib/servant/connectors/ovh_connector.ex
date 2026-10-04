defmodule Servant.Connectors.OvhConnector do
  @moduledoc """
  OVH invoice connector on the official signed API: no browser, no password,
  no 2FA at run time (unlike the Playwright provider that it replaces).

  The connector stores each new bill two times. The first is an `invoice`
  entry. The second is its PDF, in the Files app under a root "Invoices"
  folder. The `data.url` of the invoice entry points at the local copy.

  The credentials are a triple: application key, application secret and
  consumer key. Create the triple in one page at
  https://eu.api.ovh.com/createToken with the rights `GET /me/bill` and
  `GET /me/bill/*` (validity "Unlimited"). Every request has the signature of
  OVH: sha1 over `secret+consumer+method+url+body+timestamp`. The server clock
  from `/auth/time` corrects the timestamp.
  """

  use Servant.Connectors.Connector

  require Logger

  alias Servant.Data
  alias Servant.Storage

  @default_endpoint "https://eu.api.ovh.com/1.0"
  @invoices_folder "Invoices"

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
           endpoint: endpoint,
           user_id: config_value(config, "user_id")
         }}
    end
  end

  @impl true
  def sync(state) do
    with {:ok, drift} <- time_drift(state),
         {:ok, ids} <- list_bill_ids(state, drift),
         {:ok, bills} <- fetch_bills(state, new_ids(ids, known_ids(state)), drift) do
      folder_id =
        if bills != [] and is_binary(state.user_id) do
          invoices_folder_id(state.user_id)
        end

      {:ok, Enum.flat_map(bills, &bill_entries(&1, state, folder_id)), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A bill id maps 1:1 onto the entry external_id. As a result, this function
  # drops the imported bills before the fetch of their detail (and PDF). Every
  # sync pays only for what is new, and no blob is stored two times.
  @doc false
  def new_ids(ids, known) do
    Enum.reject(ids, fn id -> "ovh-#{id}" in known end)
  end

  defp known_ids(%{user_id: user_id}) when is_binary(user_id) do
    user_id
    |> Data.all_entries(%{"kind" => "invoice", "source" => "ovh"})
    |> MapSet.new(& &1.external_id)
  end

  defp known_ids(_state), do: MapSet.new()

  # One bill becomes an invoice entry, plus a PDF file entry in the Files
  # app when the download works. A failed download does not stop the sync,
  # and the invoice entry uses the remote link of OVH as the fallback.
  defp bill_entries(bill, state, folder_id) do
    case store_pdf(bill, state, folder_id) do
      {:ok, file_entry, local_path} -> [build_entry(bill, local_path), file_entry]
      :skip -> [build_entry(bill)]
    end
  end

  defp store_pdf(bill, state, folder_id) do
    pdf_url = bill["pdfUrl"] || bill["url"]

    with true <- is_binary(pdf_url) and is_binary(state.user_id),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.get(pdf_url, Servant.HTTP.req_options()),
         {:ok, relative} <- write_blob(state.user_id, body) do
      local_path = Storage.public_url(relative)
      {:ok, file_entry(bill, local_path, byte_size(body), folder_id), local_path}
    else
      other ->
        Logger.warning("OVH invoice PDF skipped for #{bill["billId"]}: #{inspect(other)}")
        :skip
    end
  end

  defp write_blob(user_id, body) do
    workspace = Storage.tmp_workspace(user_id)
    tmp_path = Path.join(workspace, "invoice.pdf")

    try do
      File.write!(tmp_path, body)

      with {:ok, relative, _absolute} <-
             Storage.store_app_file(user_id, "files", tmp_path, ext: ".pdf") do
        {:ok, relative}
      end
    after
      Storage.cleanup_tmp(workspace)
    end
  end

  defp file_entry(bill, local_path, size, folder_id) do
    filename = pdf_filename(bill)

    %{
      "kind" => "file",
      "source" => "ovh",
      "external_id" => "ovh-pdf-#{bill["billId"]}",
      "title" => filename,
      "occurred_at" => parse_datetime(bill["date"]),
      "data" => %{
        "filename" => filename,
        "path" => local_path,
        "size" => size,
        "mime_type" => "application/pdf",
        "parent_id" => folder_id
      },
      "metadata" => %{}
    }
  end

  @doc false
  def pdf_filename(bill) do
    date = String.slice(to_string(bill["date"] || ""), 0, 10)
    parts = Enum.reject(["ovh", date, to_string(bill["billId"])], &(&1 == ""))
    Enum.join(parts, "-") <> ".pdf"
  end

  # The Files app is a flat entry tree. This function finds the shared
  # "Invoices" root folder by name (whoever created it), or creates it once.
  # ponytail: the folder data is in JSON, so the lookup scans the file entries
  # in memory. Add an index if a file tree makes that visible.
  defp invoices_folder_id(user_id) do
    folder =
      user_id
      |> Data.all_entries(%{"kind" => "file"})
      |> Enum.find(fn entry ->
        entry.data["is_folder"] == true and entry.data["filename"] == @invoices_folder and
          (entry.data["parent_id"] || nil) == nil
      end)

    case folder do
      %{id: id} ->
        id

      nil ->
        case Data.create_entry(user_id, %{
               kind: "file",
               source: "ovh",
               title: @invoices_folder,
               data: %{
                 "filename" => @invoices_folder,
                 "is_folder" => true,
                 "parent_id" => nil
               }
             }) do
          {:ok, entry} -> entry.id
          _ -> nil
        end
    end
  end

  @doc false
  def signature(app_secret, consumer_key, method, url, body, timestamp) do
    payload = Enum.join([app_secret, consumer_key, method, url, body, timestamp], "+")
    "$1$" <> Base.encode16(:crypto.hash(:sha, payload), case: :lower)
  end

  @doc false
  def build_entry(bill, local_path \\ nil) do
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
        "url" => local_path || bill["pdfUrl"] || bill["url"],
        "remote_url" => bill["pdfUrl"] || bill["url"]
      },
      "metadata" => %{}
    }
  end

  defp trimmed(config, key) do
    String.trim(to_string(config_value(config, key, "")))
  end

  # The signature covers a timestamp that OVH compares with its own clock. If
  # the server clock drifts, every call gets a 403. Sync on the OVH clock once
  # per run.
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

  # No cap. new_ids/2 already reduces the work to the bills not seen before, so
  # the full history costs only one first sync.
  defp list_bill_ids(state, drift) do
    case get_signed(state, "/me/bill", drift) do
      {:ok, ids} when is_list(ids) -> {:ok, Enum.sort(ids)}
      {:ok, other} -> {:error, "unexpected /me/bill payload: #{inspect(other)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # There is no cursor: the caller gives only the ids that new_ids/2 kept. The
  # entry dedup on external_id makes a new fetch of a known bill harmless.
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
