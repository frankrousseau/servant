defmodule Servant.Connectors.StravaConnector do
  @moduledoc """
  Connector that fetches activities from Strava using the V3 API.

  Requires the user to create a Strava API app and provide their
  client_id, client_secret, and refresh_token in the config.
  The connector handles access token refresh automatically.
  """

  use Servant.Connectors.Connector

  require Logger

  @api_base "https://www.strava.com/api/v3"
  @token_url "https://www.strava.com/api/v3/oauth/token"
  @per_page 100

  @impl true
  def id, do: "strava"

  @impl true
  def name, do: "Strava"

  @impl true
  def required_credentials, do: [:client_id, :client_secret, :refresh_token]

  @impl true
  def kind, do: "activity"

  @impl true
  def default_schedule, do: "every_hour"

  @impl true
  def init(_credentials, config) do
    client_id = Map.get(config, "client_id")
    client_secret = Map.get(config, "client_secret")
    refresh_token = Map.get(config, "refresh_token")

    cond do
      is_nil(client_id) or client_id == "" ->
        {:error, "client_id is required"}

      is_nil(client_secret) or client_secret == "" ->
        {:error, "client_secret is required"}

      is_nil(refresh_token) or refresh_token == "" ->
        {:error, "refresh_token is required"}

      true ->
        {:ok,
         %{
           client_id: client_id,
           client_secret: client_secret,
           refresh_token: refresh_token
         }}
    end
  end

  @impl true
  def sync(state) do
    with {:ok, access_token, state} <- ensure_access_token(state),
         {:ok, activities} <- fetch_all_activities(access_token) do
      entries = Enum.map(activities, &build_entry/1)
      {:ok, entries, state}
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # --- Token management ---

  defp ensure_access_token(state) do
    case Servant.Connectors.get_env("strava", "tokens", state.client_id) do
      %{"access_token" => token, "expires_at" => expires_at} ->
        if DateTime.utc_now() |> DateTime.to_unix() < expires_at - 300 do
          {:ok, token, state}
        else
          refresh_access_token(state)
        end

      _ ->
        refresh_access_token(state)
    end
  end

  defp refresh_access_token(state) do
    body = %{
      client_id: state.client_id,
      client_secret: state.client_secret,
      grant_type: "refresh_token",
      refresh_token: state.refresh_token
    }

    case Req.post(@token_url, Servant.HTTP.req_options(json: body)) do
      {:ok, %Req.Response{status: 200, body: resp}} ->
        access_token = resp["access_token"]
        expires_at = resp["expires_at"]
        new_refresh = resp["refresh_token"]

        # Cache the token with expiration
        exp_dt = DateTime.from_unix!(expires_at)
        Servant.Connectors.put_env("strava", "tokens", state.client_id, %{
          "access_token" => access_token,
          "expires_at" => expires_at
        }, exp_dt)

        # Update refresh_token if Strava rotated it
        new_state =
          if new_refresh && new_refresh != state.refresh_token do
            Logger.info("Strava refresh token rotated for client #{state.client_id}")
            %{state | refresh_token: new_refresh}
          else
            state
          end

        {:ok, access_token, new_state}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = body["message"] || "HTTP #{status}"
        {:error, "Token refresh failed: #{msg}", state}

      {:error, reason} ->
        {:error, "Token refresh failed: #{inspect(reason)}", state}
    end
  end

  # --- Activities fetching ---

  defp fetch_all_activities(access_token) do
    fetch_activities_page(access_token, 1, [])
  end

  defp fetch_activities_page(access_token, page, acc) do
    headers = [{"authorization", "Bearer #{access_token}"}]
    url = "#{@api_base}/athlete/activities?per_page=#{@per_page}&page=#{page}"

    case Req.get(url, Servant.HTTP.req_options(headers: headers)) do
      {:ok, %Req.Response{status: 200, body: activities}} when is_list(activities) ->
        all = acc ++ activities

        if length(activities) == @per_page do
          fetch_activities_page(access_token, page + 1, all)
        else
          {:ok, all}
        end

      {:ok, %Req.Response{status: 401}} ->
        {:error, "Unauthorized — check your Strava credentials"}

      {:ok, %Req.Response{status: 429}} ->
        {:error, "Strava rate limit exceeded — try again later"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = if is_map(body), do: body["message"], else: nil
        {:error, "Strava API error #{status}#{if msg, do: ": #{msg}", else: ""}"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  # --- Entry building ---

  defp build_entry(activity) do
    occurred_at =
      case DateTime.from_iso8601(activity["start_date"] || "") do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> DateTime.utc_now() |> DateTime.truncate(:second)
      end

    sport = activity["sport_type"] || activity["type"] || "Unknown"
    distance_km = Float.round((activity["distance"] || 0) / 1000, 2)
    moving_min = div(activity["moving_time"] || 0, 60)

    title =
      activity["name"] ||
        "#{sport} — #{distance_km} km in #{moving_min} min"

    %{
      "kind" => "activity",
      "source" => "strava",
      "external_id" => to_string(activity["id"]),
      "title" => title,
      "occurred_at" => occurred_at,
      "data" => %{
        "sport_type" => sport,
        "distance" => activity["distance"],
        "distance_km" => distance_km,
        "moving_time" => activity["moving_time"],
        "elapsed_time" => activity["elapsed_time"],
        "total_elevation_gain" => activity["total_elevation_gain"],
        "average_speed" => activity["average_speed"],
        "max_speed" => activity["max_speed"],
        "average_heartrate" => activity["average_heartrate"],
        "max_heartrate" => activity["max_heartrate"],
        "average_watts" => activity["average_watts"],
        "kilojoules" => activity["kilojoules"],
        "kudos_count" => activity["kudos_count"],
        "achievement_count" => activity["achievement_count"],
        "start_latlng" => activity["start_latlng"],
        "end_latlng" => activity["end_latlng"]
      },
      "metadata" => %{
        "strava_id" => activity["id"],
        "device_name" => activity["device_name"],
        "trainer" => activity["trainer"],
        "commute" => activity["commute"],
        "gear_id" => activity["gear_id"]
      }
    }
  end
end
