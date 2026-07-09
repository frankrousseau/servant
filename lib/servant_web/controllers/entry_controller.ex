defmodule ServantWeb.EntryController do
  @moduledoc "User-scoped CRUD over entries, plus stats and media backfill."

  use ServantWeb, :controller

  alias Servant.ApiTokens.Scopes
  alias Servant.Data
  alias Servant.Data.Entry

  plug ServantWeb.Plugs.Scope,
       [domain: "data"] when action in [:kinds, :sources, :stats, :daily_stats]

  def index(conn, params) do
    user_id = conn.assigns.current_user.id

    case restrict_params(params, conn.assigns[:api_scopes]) do
      {:ok, params} ->
        entries = Data.list_entries(user_id, params)
        total = Data.count_entries(user_id, params)

        per_page = Data.clamp_per_page(params["per_page"])
        page = max(parse_int(params["page"], 1), 1)
        total_pages = max(ceil(total / per_page), 1)

        json(conn, %{
          data: Enum.map(entries, &Entry.to_json/1),
          meta: %{page: page, per_page: per_page, total: total, total_pages: total_pages}
        })

      {:error, required} ->
        forbidden(conn, required)
    end
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
    # Supervised, one job per user in flight (see Servant.Media.Backfill): a
    # user can't stack concurrent full-library reprocessing jobs. The client
    # polls its photo list to see results land.
    Servant.Media.Backfill.start(conn.assigns.current_user.id)

    json(conn, %{status: "started"})
  end

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    entry = Data.get_entry!(user_id, id)

    if Scopes.can_kind?(conn.assigns[:api_scopes], entry.kind, :read) do
      json(conn, %{data: Entry.to_json(entry)})
    else
      forbidden(conn, required_for(entry.kind, :read))
    end
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id
    kind = params["kind"]

    if Scopes.can_kind?(conn.assigns[:api_scopes], kind, :write) do
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
    else
      forbidden(conn, required_for(kind, :write))
    end
  end

  def update(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id
    scopes = conn.assigns[:api_scopes]
    entry = Data.get_entry!(user_id, id)
    new_kind = Map.get(params, "kind", entry.kind)

    cond do
      not Scopes.can_kind?(scopes, entry.kind, :write) ->
        forbidden(conn, required_for(entry.kind, :write))

      not Scopes.can_kind?(scopes, new_kind, :write) ->
        forbidden(conn, required_for(new_kind, :write))

      true ->
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
  end

  def delete(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    entry = Data.get_entry!(user_id, id)

    if Scopes.can_kind?(conn.assigns[:api_scopes], entry.kind, :write) do
      case Data.delete_entry(user_id, id) do
        {:ok, _entry} ->
          send_resp(conn, :no_content, "")

        {:error, _reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Could not delete entry"})
      end
    else
      forbidden(conn, required_for(entry.kind, :write))
    end
  end

  # Session tokens see everything. An explicit kind filter outside the token's
  # scopes is a 403; without one, the query is restricted to readable kinds.
  defp restrict_params(params, nil), do: {:ok, params}

  defp restrict_params(%{"kind" => kind} = params, scopes) do
    if Scopes.can_kind?(scopes, kind, :read) do
      {:ok, params}
    else
      {:error, required_for(kind, :read)}
    end
  end

  defp restrict_params(params, scopes) do
    case Scopes.readable_kinds(scopes) do
      :all -> {:ok, params}
      kinds -> {:ok, Map.put(params, "kinds", kinds)}
    end
  end

  defp required_for(kind, action) do
    Scopes.scope_name(Scopes.kind_domain(kind) || "data", action)
  end

  defp forbidden(conn, required) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Insufficient scope", required: required})
  end

  defp parse_int(val, default), do: Servant.Util.parse_int(val, default)
end
