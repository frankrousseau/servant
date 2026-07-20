defmodule ServantWeb.EntryController do
  @moduledoc "User-scoped CRUD over entries, plus stats and media backfill."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Servant.ApiTokens.Scopes
  alias Servant.Data
  alias Servant.Data.Entry
  alias ServantWeb.Schemas

  plug ServantWeb.Plugs.Scope,
       [domain: "data"] when action in [:kinds, :sources, :stats, :daily_stats]

  tags(["entries"])

  @entry_page %Schema{
    type: :object,
    properties: %{
      data: %Schema{type: :array, items: Schemas.Entry},
      meta: Schemas.PaginationMeta
    }
  }
  @entry_envelope %Schema{type: :object, properties: %{data: Schemas.Entry}}

  operation(:index,
    summary: "List entries",
    description:
      "Filterable, paginated. API tokens only see kinds their scopes can read; an explicit kind filter outside the scopes returns 403.",
    parameters: [
      kind: [in: :query, type: :string, required: false],
      source: [in: :query, type: :string, required: false],
      q: [in: :query, type: :string, required: false, description: "substring search"],
      from: [
        in: :query,
        type: :string,
        required: false,
        description: "ISO8601 lower bound on occurred_at"
      ],
      to: [in: :query, type: :string, required: false],
      sort: [
        in: :query,
        type: :string,
        required: false,
        description: "inserted_at for newest-first by creation"
      ],
      page: [in: :query, type: :integer, required: false],
      per_page: [in: :query, type: :integer, required: false]
    ],
    responses: [
      ok: {"Entries page", "application/json", @entry_page},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

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

  operation(:kinds,
    summary: "List distinct entry kinds",
    description: "Requires data:read for an API token.",
    responses: [
      ok:
        {"Kinds", "application/json",
         %Schema{
           type: :object,
           properties: %{data: %Schema{type: :array, items: %Schema{type: :string}}}
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def kinds(conn, _params) do
    user_id = conn.assigns.current_user.id
    kinds = Data.list_kinds(user_id)
    json(conn, %{data: kinds})
  end

  operation(:sources,
    summary: "List distinct entry sources",
    description: "Requires data:read for an API token.",
    responses: [
      ok:
        {"Sources", "application/json",
         %Schema{
           type: :object,
           properties: %{data: %Schema{type: :array, items: %Schema{type: :string}}}
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def sources(conn, _params) do
    user_id = conn.assigns.current_user.id
    sources = Data.list_sources(user_id)
    json(conn, %{data: sources})
  end

  operation(:stats,
    summary: "Entry counts by kind",
    description: "Requires data:read for an API token.",
    responses: [
      ok:
        {"Stats", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{type: :object, additionalProperties: true},
             total: %Schema{type: :integer}
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def stats(conn, _params) do
    user_id = conn.assigns.current_user.id
    stats = Data.stats(user_id)
    total = Enum.reduce(stats, 0, fn {_k, v}, acc -> acc + v end)
    json(conn, %{data: stats, total: total})
  end

  operation(:daily_stats,
    summary: "Entry counts per day",
    description: "Requires data:read for an API token.",
    parameters: [
      days: [
        in: :query,
        type: :integer,
        required: false,
        description: "window size, 1..90, defaults to 30"
      ]
    ],
    responses: [
      ok:
        {"Daily stats", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{type: :object, additionalProperties: true},
             days: %Schema{type: :integer}
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def daily_stats(conn, params) do
    user_id = conn.assigns.current_user.id

    days =
      case Integer.parse(params["days"] || "30") do
        {n, ""} when n in 1..90 -> n
        _ -> 30
      end

    json(conn, %{data: Data.daily_stats(user_id, days), days: days})
  end

  operation(:aggregate,
    summary: "Aggregate entries per day, week, month or year",
    description:
      "COUNT of entries or SUM of a numeric data field, bucketed by local day/week/month/year in the given timezone (defaults to the account's timezone preference). Accepts the same filters as the entry list; entries without occurred_at are skipped. API token scope rules match the list endpoint.",
    parameters: [
      kind: [in: :query, type: :string, required: false],
      source: [in: :query, type: :string, required: false],
      q: [in: :query, type: :string, required: false, description: "substring search"],
      from: [
        in: :query,
        type: :string,
        required: false,
        description: "ISO8601 lower bound on occurred_at"
      ],
      to: [in: :query, type: :string, required: false],
      agg: [
        in: :query,
        type: :string,
        required: false,
        description: "count (default) or sum"
      ],
      field: [
        in: :query,
        type: :string,
        required: false,
        description: "data key to sum, required when agg=sum"
      ],
      bucket: [
        in: :query,
        type: :string,
        required: false,
        description: "day (default), week (ISO week's Monday), month or year"
      ],
      tz: [
        in: :query,
        type: :string,
        required: false,
        description: "IANA timezone, defaults to the account timezone"
      ]
    ],
    responses: [
      ok:
        {"Aggregates", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 properties: %{
                   bucket: %Schema{type: :string, description: "YYYY-MM-DD local day"},
                   value: %Schema{type: :number}
                 }
               }
             },
             agg: %Schema{type: :string},
             bucket: %Schema{type: :string},
             tz: %Schema{type: :string}
           }
         }},
      bad_request: {"Invalid parameters", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def aggregate(conn, params) do
    user_id = conn.assigns.current_user.id

    with {:ok, params} <- restrict_params(params, conn.assigns[:api_scopes]),
         {:ok, opts} <- aggregate_opts(conn, params) do
      json(conn, %{
        data: Data.aggregate_entries(user_id, params, opts),
        agg: opts.agg,
        bucket: opts.bucket,
        tz: opts.tz
      })
    else
      {:error, required} ->
        forbidden(conn, required)

      {:bad_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: message})
    end
  end

  defp aggregate_opts(conn, params) do
    agg = params["agg"] || "count"
    field = params["field"]
    bucket = params["bucket"] || "day"
    tz = params["tz"] || conn.assigns.current_user.timezone || "UTC"

    cond do
      agg not in ["count", "sum"] ->
        {:bad_request, "agg must be count or sum"}

      bucket not in ["day", "week", "month", "year"] ->
        {:bad_request, "bucket must be day, week, month or year"}

      agg == "sum" and not (is_binary(field) and field =~ ~r/^\w+$/) ->
        {:bad_request, "agg=sum requires field, a key of the entry data object"}

      match?({:error, _}, DateTime.shift_zone(DateTime.utc_now(), tz)) ->
        {:bad_request, "invalid timezone"}

      true ->
        {:ok, %{agg: agg, field: field, bucket: bucket, tz: tz}}
    end
  end

  operation(:backfill_media,
    summary: "Regenerate missing photo previews",
    description:
      "Session-only (API tokens cannot call this). Starts a background job (one per user in flight) that regenerates missing thumbnails and display JPEGs; poll the photos list for results.",
    responses: [
      ok:
        {"Started", "application/json",
         %Schema{
           type: :object,
           properties: %{status: %Schema{type: :string}}
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

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

  operation(:rotate_photo,
    summary: "Rotate a photo",
    description:
      "Session-only (API tokens cannot call this). Rotates the photo's original file clockwise by `angle` degrees (90, 180 or 270), regenerates its thumbnail and display JPEG, and returns the updated entry.",
    parameters: [
      id: [in: :path, type: :string, required: true],
      angle: [in: :query, type: :integer, required: true]
    ],
    responses: [
      ok: {"Entry", "application/json", @entry_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Rotation failed", "application/json", Schemas.Error}
    ]
  )

  def rotate_photo(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id
    entry = Data.get_entry!(user_id, id)
    mime = entry.data["mime_type"] || ""

    cond do
      entry.kind != "photo" or String.starts_with?(mime, "video/") ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Only photos can be rotated"})

      true ->
        case Servant.Media.PhotoEdit.rotate(entry, parse_angle(params["angle"])) do
          {:ok, entry} ->
            json(conn, %{data: Entry.to_json(entry)})

          {:error, message} when is_binary(message) ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: message})

          {:error, _changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "rotation failed"})
        end
    end
  end

  defp parse_angle(angle) when is_binary(angle) do
    case Integer.parse(angle) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_angle(angle), do: angle

  operation(:show,
    summary: "Get one entry",
    description: "Requires read scope on the entry's kind domain for an API token.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Entry", "application/json", @entry_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    entry = Data.get_entry!(user_id, id)

    if Scopes.can_kind?(conn.assigns[:api_scopes], entry.kind, :read) do
      json(conn, %{data: Entry.to_json(entry)})
    else
      forbidden(conn, required_for(entry.kind, :read))
    end
  end

  operation(:create,
    summary: "Create an entry",
    description:
      "Requires write scope on the kind's domain for an API token. Notes cannot be created here (use /api/notes).",
    request_body:
      {"Entry attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           kind: %Schema{type: :string},
           source: %Schema{type: :string},
           title: %Schema{type: :string},
           occurred_at: %Schema{type: :string, format: :"date-time"},
           data: %Schema{type: :object, additionalProperties: true}
         },
         required: [:kind, :source]
       }},
    responses: [
      created: {"Entry", "application/json", @entry_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user_id = conn.assigns.current_user.id
    kind = params["kind"]

    if Scopes.can_kind?(conn.assigns[:api_scopes], kind, :write) do
      case Data.create_entry(user_id, params) do
        {:ok, entry} ->
          conn
          |> put_status(:created)
          |> json(%{data: Entry.to_json(entry)})

        {:error, :notes_api_required} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Notes must be created through the notes API (/api/notes)"})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      forbidden(conn, required_for(kind, :write))
    end
  end

  operation(:update,
    summary: "Update an entry",
    description:
      "Requires write scope on both the entry's current and (if changing) new kind domain for an API token. Notes cannot be edited here (use /api/notes).",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Entry attributes", "application/json",
       %Schema{type: :object, properties: %{}, additionalProperties: true}},
    responses: [
      ok: {"Entry", "application/json", @entry_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

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

  operation(:delete,
    summary: "Delete an entry",
    description: "Requires write scope on the entry's kind domain for an API token.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Delete failed", "application/json", Schemas.Error}
    ]
  )

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

  operation(:delete_by_kind,
    summary: "Delete all entries of a kind",
    description: "Requires write scope on the kind's domain for an API token.",
    parameters: [kind: [in: :query, type: :string, required: true]],
    responses: [
      ok: {"Deleted count", "application/json", Schemas.DeletedCount},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def delete_by_kind(conn, %{"kind" => kind}) when is_binary(kind) and kind != "" do
    user_id = conn.assigns.current_user.id

    if Scopes.can_kind?(conn.assigns[:api_scopes], kind, :write) do
      count = Data.delete_entries_by_kind(user_id, kind)
      json(conn, %{deleted: count})
    else
      forbidden(conn, required_for(kind, :write))
    end
  end

  def delete_by_kind(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "kind query parameter is required"})
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
