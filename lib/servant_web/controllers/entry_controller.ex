defmodule ServantWeb.EntryController do
  @moduledoc "User-scoped CRUD over entries, plus stats and media backfill."

  use ServantWeb, :controller

  alias Servant.Data
  alias Servant.Data.Entry

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    entries = Data.list_entries(user_id, params)
    total = Data.count_entries(user_id, params)

    per_page = Data.clamp_per_page(params["per_page"])
    page = max(parse_int(params["page"], 1), 1)
    total_pages = max(ceil(total / per_page), 1)

    json(conn, %{
      data: Enum.map(entries, &Entry.to_json/1),
      meta: %{page: page, per_page: per_page, total: total, total_pages: total_pages}
    })
  end

  def kinds(conn, _params) do
    user_id = conn.assigns.current_user.id
    kinds = Data.list_kinds(user_id)
    json(conn, %{data: kinds})
  end

  def sources(conn, _params) do
    user_id = conn.assigns.current_user.id
    sources = Data.list_sources(user_id)
    json(conn, %{data: sources})
  end

  def stats(conn, _params) do
    user_id = conn.assigns.current_user.id
    stats = Data.stats(user_id)
    total = Enum.reduce(stats, 0, fn {_k, v}, acc -> acc + v end)
    json(conn, %{data: stats, total: total})
  end

  def daily_stats(conn, params) do
    user_id = conn.assigns.current_user.id

    days =
      case Integer.parse(params["days"] || "30") do
        {n, ""} when n in 1..90 -> n
        _ -> 30
      end

    json(conn, %{data: Data.daily_stats(user_id, days), days: days})
  end

  @doc """
  Regenerates missing photo previews (thumbnails + display JPEGs) for the
  caller. Runs in the background; the client polls its photo list to see
  results land.
  """
  def backfill_media(conn, _params) do
    user_id = conn.assigns.current_user.id

    # ponytail: fire-and-forget Task, no progress reporting — the client
    # polls. Move under a Task.Supervisor if this ever needs shutdown safety.
    Task.start(fn -> Servant.Media.Thumbnail.backfill_missing(user_id) end)

    json(conn, %{status: "started"})
  end

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    entry = Data.get_entry!(user_id, id)
    json(conn, %{data: Entry.to_json(entry)})
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case Data.create_entry(user_id, params) do
      {:ok, entry} ->
        conn
        |> put_status(:created)
        |> json(%{data: Entry.to_json(entry)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id

    case Data.update_entry(user_id, id, params) do
      {:ok, entry} ->
        json(conn, %{data: Entry.to_json(entry)})

      {:error, :notes_api_required} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Notes must be edited through the notes API (/api/notes)"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Data.delete_entry(user_id, id) do
      {:ok, _entry} ->
        send_resp(conn, :no_content, "")

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not delete entry"})
    end
  end

  defp parse_int(val, default), do: Servant.Util.parse_int(val, default)
end
