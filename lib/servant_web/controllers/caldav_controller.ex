defmodule ServantWeb.CalDAVController do
  @moduledoc """
  Minimal CalDAV (RFC 4791) server for phone calendar sync, exercised
  against the discovery + sync flows of iOS Calendar and DAVx5.

  Layout: `/dav` -> `/dav/principals/:uid/` -> `/dav/calendars/:uid/`
  (home set) -> one collection per Servant calendar -> `<name>.ics`
  event resources.

  Simplifications, on purpose: PROPFIND ignores the requested prop list
  and always answers the full supported set for the resource type
  (clients ignore extras); calendar-query returns the whole collection
  (clients filter locally); REPORT hrefs are extracted with a regex
  rather than an XML parser. Upgrade to xmerl_sax if a client chokes.
  """

  use ServantWeb, :controller

  alias Servant.ApiTokens.Scopes
  alias Servant.CalDAV
  alias Servant.CalDAV.ICS

  @dav_compliance "1, 3, calendar-access"
  @allow "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, REPORT"

  def well_known(conn, _params) do
    conn
    |> put_resp_header("location", "/dav")
    |> send_resp(301, "")
  end

  def dav(conn, %{"path" => segments}) do
    case conn.method do
      "OPTIONS" -> send_options(conn)
      "PROPFIND" -> authorized(conn, :read, &propfind(&1, segments))
      "REPORT" -> authorized(conn, :read, &report(&1, segments))
      "GET" -> authorized(conn, :read, &get_event(&1, segments))
      "PUT" -> authorized(conn, :write, &put_event(&1, segments))
      "DELETE" -> authorized(conn, :write, &delete_event(&1, segments))
      "PROPPATCH" -> send_resp(conn, 403, "")
      _ -> conn |> put_resp_header("allow", @allow) |> send_resp(405, "")
    end
  end

  defp send_options(conn) do
    conn
    |> put_resp_header("dav", @dav_compliance)
    |> put_resp_header("allow", @allow)
    |> send_resp(200, "")
  end

  defp authorized(conn, action, fun) do
    if Scopes.can?(conn.assigns.api_scopes, "calendar", action) do
      fun.(conn)
    else
      send_resp(conn, 403, "Requires the #{Scopes.scope_name("calendar", action)} scope")
    end
  end

  defp user(conn), do: conn.assigns.current_user
  defp user_tz(conn), do: user(conn).timezone || "Etc/UTC"

  # ----- PROPFIND -----

  defp propfind(conn, []) do
    multistatus(conn, [response_xml("/dav/", root_props(user(conn)))])
  end

  defp propfind(conn, ["principals", uid]) do
    with_owner(conn, uid, fn ->
      multistatus(conn, [response_xml(principal_href(user(conn)), principal_props(user(conn)))])
    end)
  end

  defp propfind(conn, ["calendars", uid]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      home = [response_xml(home_href(u), home_props())]

      children =
        if depth(conn) > 0 do
          for cal <- CalDAV.calendars(u.id) do
            response_xml(cal_href(u, cal), collection_props(u.id, cal))
          end
        else
          []
        end

      multistatus(conn, home ++ children)
    end)
  end

  defp propfind(conn, ["calendars", uid, cal]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      self_resp = [response_xml(cal_href(u, cal), collection_props(u.id, cal))]

      children =
        if depth(conn) > 0 do
          for event <- CalDAV.events(u.id, cal) do
            response_xml(event_href(u, cal, event), event_props(event))
          end
        else
          []
        end

      multistatus(conn, self_resp ++ children)
    end)
  end

  defp propfind(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)

      case CalDAV.get_event(u.id, cal, name) do
        nil -> send_resp(conn, 404, "")
        event -> multistatus(conn, [response_xml(event_href(u, cal, event), event_props(event))])
      end
    end)
  end

  defp propfind(conn, _), do: send_resp(conn, 404, "")

  # ----- REPORT (calendar-multiget / calendar-query) -----

  defp report(conn, ["calendars", uid, cal]) do
    with_calendar(conn, uid, cal, fn ->
      {:ok, body, conn} = read_body(conn)
      u = user(conn)

      responses =
        if String.contains?(body, "calendar-multiget") do
          for href <- extract_hrefs(body) do
            name = href |> Path.basename() |> URI.decode()

            case CalDAV.get_event(u.id, cal, name) do
              nil -> not_found_xml(href)
              event -> response_xml(event_href(u, cal, event), event_data_props(event, conn))
            end
          end
        else
          for event <- CalDAV.events(u.id, cal) do
            response_xml(event_href(u, cal, event), event_data_props(event, conn))
          end
        end

      multistatus(conn, responses)
    end)
  end

  defp report(conn, _), do: send_resp(conn, 404, "")

  # Client REPORT bodies are machine-generated; a regex is enough to pull
  # the requested hrefs out.
  defp extract_hrefs(body) do
    ~r|<[^>]*?href[^>]*?>\s*([^<]+?)\s*</|i
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  # ----- GET / PUT / DELETE on event resources -----

  defp get_event(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      case CalDAV.get_event(user(conn).id, cal, name) do
        nil ->
          send_resp(conn, 404, "")

        event ->
          conn
          |> put_resp_header("etag", CalDAV.etag(event))
          |> put_resp_content_type("text/calendar")
          |> send_resp(200, ICS.to_ics(event, user_tz(conn)))
      end
    end)
  end

  defp get_event(conn, _), do: send_resp(conn, 404, "")

  defp put_event(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      {:ok, body, conn} = read_body(conn)
      existing = CalDAV.get_event(u.id, cal, name)

      cond do
        get_req_header(conn, "if-none-match") == ["*"] and existing != nil ->
          send_resp(conn, 412, "")

        not etag_matches?(conn, existing) ->
          send_resp(conn, 412, "")

        true ->
          case CalDAV.put_event(u.id, cal, name, body, user_tz(conn)) do
            {:ok, entry, verb} ->
              conn
              |> put_resp_header("etag", CalDAV.etag(entry))
              |> send_resp(if(verb == :created, do: 201, else: 204), "")

            {:error, reason} when is_binary(reason) ->
              send_resp(conn, 400, reason)

            {:error, _changeset} ->
              send_resp(conn, 409, "")
          end
      end
    end)
  end

  defp put_event(conn, _), do: send_resp(conn, 404, "")

  defp delete_event(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)

      case CalDAV.get_event(u.id, cal, name) do
        nil ->
          send_resp(conn, 404, "")

        event ->
          if etag_matches?(conn, event) do
            {:ok, _} = CalDAV.delete_event(u.id, event)
            send_resp(conn, 204, "")
          else
            send_resp(conn, 412, "")
          end
      end
    end)
  end

  defp delete_event(conn, _), do: send_resp(conn, 404, "")

  # If-Match precondition; absence always passes.
  defp etag_matches?(conn, existing) do
    case get_req_header(conn, "if-match") do
      [] -> true
      ["*"] -> existing != nil
      [tag] -> existing != nil and tag == CalDAV.etag(existing)
      _ -> false
    end
  end

  # ----- guards -----

  defp with_owner(conn, uid, fun) do
    if uid == user(conn).id, do: fun.(), else: send_resp(conn, 404, "")
  end

  defp with_calendar(conn, uid, cal, fun) do
    cond do
      uid != user(conn).id -> send_resp(conn, 404, "")
      cal not in CalDAV.calendars(user(conn).id) -> send_resp(conn, 404, "")
      true -> fun.()
    end
  end

  defp depth(conn) do
    case get_req_header(conn, "depth") do
      ["0"] -> 0
      _ -> 1
    end
  end

  # ----- hrefs -----

  defp principal_href(u), do: "/dav/principals/#{u.id}/"
  defp home_href(u), do: "/dav/calendars/#{u.id}/"
  defp cal_href(u, cal), do: home_href(u) <> encode_segment(cal) <> "/"

  defp event_href(u, cal, event),
    do: cal_href(u, cal) <> encode_segment(CalDAV.resource_name(event))

  defp encode_segment(seg), do: URI.encode(seg, &URI.char_unreserved?/1)

  # ----- prop sets -----
  # Fixed per resource type; see @moduledoc.

  defp root_props(u) do
    [
      "<d:resourcetype><d:collection/></d:resourcetype>",
      current_user_principal(u)
    ]
  end

  defp principal_props(u) do
    [
      "<d:resourcetype><d:principal/></d:resourcetype>",
      "<d:displayname>",
      xml_escape(u.display_name || u.username),
      "</d:displayname>",
      current_user_principal(u),
      "<d:principal-URL><d:href>",
      principal_href(u),
      "</d:href></d:principal-URL>",
      "<c:calendar-home-set><d:href>",
      home_href(u),
      "</d:href></c:calendar-home-set>",
      "<c:calendar-user-address-set><d:href>mailto:",
      xml_escape(u.email || u.username),
      "</d:href></c:calendar-user-address-set>"
    ]
  end

  defp home_props do
    ["<d:resourcetype><d:collection/></d:resourcetype>", "<d:displayname>Servant</d:displayname>"]
  end

  defp collection_props(user_id, cal) do
    [
      "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>",
      "<d:displayname>",
      xml_escape(cal),
      "</d:displayname>",
      "<cs:getctag>",
      CalDAV.ctag(user_id, cal),
      "</cs:getctag>",
      "<c:supported-calendar-component-set><c:comp name=\"VEVENT\"/>",
      "</c:supported-calendar-component-set>",
      "<d:supported-report-set>",
      "<d:supported-report><d:report><c:calendar-multiget/></d:report></d:supported-report>",
      "<d:supported-report><d:report><c:calendar-query/></d:report></d:supported-report>",
      "</d:supported-report-set>",
      "<d:current-user-privilege-set>",
      "<d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege>",
      "</d:current-user-privilege-set>"
    ]
  end

  defp event_props(event) do
    [
      "<d:resourcetype/>",
      "<d:getetag>",
      xml_escape(CalDAV.etag(event)),
      "</d:getetag>",
      "<d:getcontenttype>text/calendar; charset=utf-8; component=VEVENT</d:getcontenttype>"
    ]
  end

  defp event_data_props(event, conn) do
    [
      "<d:getetag>",
      xml_escape(CalDAV.etag(event)),
      "</d:getetag>",
      "<c:calendar-data>",
      xml_escape(ICS.to_ics(event, user_tz(conn))),
      "</c:calendar-data>"
    ]
  end

  defp current_user_principal(u) do
    [
      "<d:current-user-principal><d:href>",
      principal_href(u),
      "</d:href>",
      "</d:current-user-principal>"
    ]
  end

  # ----- multistatus rendering -----

  defp multistatus(conn, responses) do
    body = [
      ~s(<?xml version="1.0" encoding="utf-8"?>\n),
      ~s(<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" ),
      ~s(xmlns:cs="http://calendarserver.org/ns/">),
      responses,
      "</d:multistatus>"
    ]

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(207, IO.iodata_to_binary(body))
  end

  defp response_xml(href, props) do
    [
      "<d:response><d:href>",
      xml_escape(href),
      "</d:href>",
      "<d:propstat><d:prop>",
      props,
      "</d:prop>",
      "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    ]
  end

  defp not_found_xml(href) do
    [
      "<d:response><d:href>",
      xml_escape(href),
      "</d:href>",
      "<d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
    ]
  end

  defp xml_escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
