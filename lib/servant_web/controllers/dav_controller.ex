defmodule ServantWeb.DavController do
  @moduledoc """
  Minimal CalDAV (RFC 4791) + CardDAV (RFC 6352) server for phone sync,
  exercised against the discovery + sync flows of iOS and DAVx5.

  Layout: `/dav` -> `/dav/principals/:uid/` -> calendar home
  `/dav/calendars/:uid/` (one collection per Servant calendar, `.ics`
  resources) and address book home `/dav/addressbooks/:uid/` (single
  `contacts` collection, `.vcf` resources).

  Simplifications, on purpose: PROPFIND ignores the requested prop list
  and always answers the full supported set for the resource type
  (clients ignore extras); calendar-query/addressbook-query return the
  whole collection (clients filter locally); REPORT hrefs are extracted
  with a regex rather than an XML parser. Upgrade to xmerl_sax if a
  client chokes.
  """

  use ServantWeb, :controller

  alias Servant.ApiTokens.Scopes
  alias Servant.CalDAV
  alias Servant.CalDAV.ICS
  alias Servant.CardDAV
  alias Servant.CardDAV.VCard
  alias Servant.Dav

  @dav_compliance "1, 3, calendar-access, addressbook"
  @allow "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, REPORT"
  @addressbook "contacts"

  def well_known(conn, _params) do
    conn
    |> put_resp_header("location", "/dav")
    |> send_resp(301, "")
  end

  def dav(conn, %{"path" => segments}) do
    case conn.method do
      "OPTIONS" -> send_options(conn)
      "PROPFIND" -> authorized(conn, segments, :read, &propfind/2)
      "REPORT" -> authorized(conn, segments, :read, &report/2)
      "GET" -> authorized(conn, segments, :read, &get_resource/2)
      "PUT" -> authorized(conn, segments, :write, &put_resource/2)
      "DELETE" -> authorized(conn, segments, :write, &delete_resource/2)
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

  defp authorized(conn, segments, action, fun) do
    scopes = conn.assigns.api_scopes

    ok? =
      case segments do
        ["calendars" | _] ->
          Scopes.can?(scopes, "calendar", action)

        ["addressbooks" | _] ->
          Scopes.can?(scopes, "contacts", action)

        # Root and principal serve the discovery of both trees.
        _ ->
          Scopes.can?(scopes, "calendar", action) or Scopes.can?(scopes, "contacts", action)
      end

    if ok? do
      fun.(conn, segments)
    else
      send_resp(conn, 403, "Insufficient token scope for this DAV tree")
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
      home = [response_xml(cal_home_href(u), home_props())]

      children =
        if depth(conn) > 0 do
          for cal <- CalDAV.calendars(u.id) do
            response_xml(cal_href(u, cal), calendar_props(u.id, cal))
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
      self_resp = [response_xml(cal_href(u, cal), calendar_props(u.id, cal))]

      children =
        if depth(conn) > 0 do
          for event <- CalDAV.events(u.id, cal) do
            response_xml(event_href(u, cal, event), resource_props(event, "text/calendar"))
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
        nil ->
          send_resp(conn, 404, "")

        event ->
          multistatus(conn, [
            response_xml(event_href(u, cal, event), resource_props(event, "text/calendar"))
          ])
      end
    end)
  end

  defp propfind(conn, ["addressbooks", uid]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      home = [response_xml(card_home_href(u), home_props())]

      children =
        if depth(conn) > 0 do
          [response_xml(book_href(u), addressbook_props(u.id))]
        else
          []
        end

      multistatus(conn, home ++ children)
    end)
  end

  defp propfind(conn, ["addressbooks", uid, @addressbook]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      self_resp = [response_xml(book_href(u), addressbook_props(u.id))]

      children =
        if depth(conn) > 0 do
          for contact <- CardDAV.contacts(u.id) do
            response_xml(contact_href(u, contact), resource_props(contact, "text/vcard"))
          end
        else
          []
        end

      multistatus(conn, self_resp ++ children)
    end)
  end

  defp propfind(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)

      case CardDAV.get_contact(u.id, name) do
        nil ->
          send_resp(conn, 404, "")

        contact ->
          multistatus(conn, [
            response_xml(contact_href(u, contact), resource_props(contact, "text/vcard"))
          ])
      end
    end)
  end

  defp propfind(conn, _), do: send_resp(conn, 404, "")

  # ----- REPORT (multiget / query) -----

  defp report(conn, ["calendars", uid, cal]) do
    with_calendar(conn, uid, cal, fn ->
      {:ok, body, conn} = read_body(conn)
      u = user(conn)
      tz = user_tz(conn)
      props = fn event -> data_props(event, ICS.to_ics(event, tz), "c:calendar-data") end

      responses =
        if String.contains?(body, "multiget") do
          for href <- extract_hrefs(body) do
            case CalDAV.get_event(u.id, cal, basename(href)) do
              nil -> not_found_xml(href)
              event -> response_xml(event_href(u, cal, event), props.(event))
            end
          end
        else
          for event <- CalDAV.events(u.id, cal) do
            response_xml(event_href(u, cal, event), props.(event))
          end
        end

      multistatus(conn, responses)
    end)
  end

  defp report(conn, ["addressbooks", uid, @addressbook]) do
    with_owner(conn, uid, fn ->
      {:ok, body, conn} = read_body(conn)
      u = user(conn)
      props = fn contact -> data_props(contact, VCard.to_vcf(contact), "card:address-data") end

      responses =
        if String.contains?(body, "multiget") do
          for href <- extract_hrefs(body) do
            case CardDAV.get_contact(u.id, basename(href)) do
              nil -> not_found_xml(href)
              contact -> response_xml(contact_href(u, contact), props.(contact))
            end
          end
        else
          for contact <- CardDAV.contacts(u.id) do
            response_xml(contact_href(u, contact), props.(contact))
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

  defp basename(href), do: href |> Path.basename() |> URI.decode()

  # ----- GET / PUT / DELETE on resources -----

  defp get_resource(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      case CalDAV.get_event(user(conn).id, cal, name) do
        nil -> send_resp(conn, 404, "")
        event -> send_payload(conn, event, "text/calendar", ICS.to_ics(event, user_tz(conn)))
      end
    end)
  end

  defp get_resource(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      case CardDAV.get_contact(user(conn).id, name) do
        nil -> send_resp(conn, 404, "")
        contact -> send_payload(conn, contact, "text/vcard", VCard.to_vcf(contact))
      end
    end)
  end

  defp get_resource(conn, _), do: send_resp(conn, 404, "")

  defp send_payload(conn, entry, content_type, payload) do
    conn
    |> put_resp_header("etag", Dav.etag(entry))
    |> put_resp_content_type(content_type)
    |> send_resp(200, payload)
  end

  defp put_resource(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      tz = user_tz(conn)

      upsert(conn, CalDAV.get_event(u.id, cal, name), fn body ->
        CalDAV.put_event(u.id, cal, name, body, tz)
      end)
    end)
  end

  defp put_resource(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      upsert(conn, CardDAV.get_contact(u.id, name), &CardDAV.put_contact(u.id, name, &1))
    end)
  end

  defp put_resource(conn, _), do: send_resp(conn, 404, "")

  defp upsert(conn, existing, put_fun) do
    {:ok, body, conn} = read_body(conn)

    cond do
      get_req_header(conn, "if-none-match") == ["*"] and existing != nil ->
        send_resp(conn, 412, "")

      not etag_matches?(conn, existing) ->
        send_resp(conn, 412, "")

      true ->
        case put_fun.(body) do
          {:ok, entry, verb} ->
            conn
            |> put_resp_header("etag", Dav.etag(entry))
            |> send_resp(if(verb == :created, do: 201, else: 204), "")

          {:error, reason} when is_binary(reason) ->
            send_resp(conn, 400, reason)

          {:error, _changeset} ->
            send_resp(conn, 409, "")
        end
    end
  end

  defp delete_resource(conn, ["calendars", uid, cal, name]) do
    with_calendar(conn, uid, cal, fn ->
      u = user(conn)
      remove(conn, CalDAV.get_event(u.id, cal, name), &CalDAV.delete_event(u.id, &1))
    end)
  end

  defp delete_resource(conn, ["addressbooks", uid, @addressbook, name]) do
    with_owner(conn, uid, fn ->
      u = user(conn)
      remove(conn, CardDAV.get_contact(u.id, name), &CardDAV.delete_contact(u.id, &1))
    end)
  end

  defp delete_resource(conn, _), do: send_resp(conn, 404, "")

  defp remove(conn, existing, delete_fun) do
    case existing do
      nil ->
        send_resp(conn, 404, "")

      entry ->
        if etag_matches?(conn, entry) do
          {:ok, _} = delete_fun.(entry)
          send_resp(conn, 204, "")
        else
          send_resp(conn, 412, "")
        end
    end
  end

  # If-Match precondition; absence always passes.
  defp etag_matches?(conn, existing) do
    case get_req_header(conn, "if-match") do
      [] -> true
      ["*"] -> existing != nil
      [tag] -> existing != nil and tag == Dav.etag(existing)
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
  defp cal_home_href(u), do: "/dav/calendars/#{u.id}/"
  defp card_home_href(u), do: "/dav/addressbooks/#{u.id}/"
  defp cal_href(u, cal), do: cal_home_href(u) <> encode_segment(cal) <> "/"
  defp book_href(u), do: card_home_href(u) <> @addressbook <> "/"

  defp event_href(u, cal, event),
    do: cal_href(u, cal) <> encode_segment(CalDAV.resource_name(event))

  defp contact_href(u, contact),
    do: book_href(u) <> encode_segment(CardDAV.resource_name(contact))

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
      cal_home_href(u),
      "</d:href></c:calendar-home-set>",
      "<card:addressbook-home-set><d:href>",
      card_home_href(u),
      "</d:href></card:addressbook-home-set>",
      "<c:calendar-user-address-set><d:href>mailto:",
      xml_escape(u.email || u.username),
      "</d:href></c:calendar-user-address-set>"
    ]
  end

  defp home_props do
    ["<d:resourcetype><d:collection/></d:resourcetype>", "<d:displayname>Servant</d:displayname>"]
  end

  defp calendar_props(user_id, cal) do
    [
      "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>",
      "<d:displayname>",
      xml_escape(cal),
      "</d:displayname>",
      "<cs:getctag>",
      Dav.ctag(CalDAV.events(user_id, cal)),
      "</cs:getctag>",
      "<c:supported-calendar-component-set><c:comp name=\"VEVENT\"/>",
      "</c:supported-calendar-component-set>",
      "<d:supported-report-set>",
      "<d:supported-report><d:report><c:calendar-multiget/></d:report></d:supported-report>",
      "<d:supported-report><d:report><c:calendar-query/></d:report></d:supported-report>",
      "</d:supported-report-set>",
      privilege_set()
    ]
  end

  defp addressbook_props(user_id) do
    [
      "<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>",
      "<d:displayname>Contacts</d:displayname>",
      "<cs:getctag>",
      Dav.ctag(CardDAV.contacts(user_id)),
      "</cs:getctag>",
      "<d:supported-report-set>",
      "<d:supported-report><d:report><card:addressbook-multiget/></d:report>",
      "</d:supported-report>",
      "<d:supported-report><d:report><card:addressbook-query/></d:report>",
      "</d:supported-report>",
      "</d:supported-report-set>",
      privilege_set()
    ]
  end

  defp privilege_set do
    [
      "<d:current-user-privilege-set>",
      "<d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege>",
      "</d:current-user-privilege-set>"
    ]
  end

  defp resource_props(entry, content_type) do
    [
      "<d:resourcetype/>",
      "<d:getetag>",
      xml_escape(Dav.etag(entry)),
      "</d:getetag>",
      "<d:getcontenttype>",
      content_type,
      "; charset=utf-8</d:getcontenttype>"
    ]
  end

  defp data_props(entry, payload, data_element) do
    [
      "<d:getetag>",
      xml_escape(Dav.etag(entry)),
      "</d:getetag>",
      "<",
      data_element,
      ">",
      xml_escape(payload),
      "</",
      data_element,
      ">"
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
      ~s(xmlns:card="urn:ietf:params:xml:ns:carddav" ),
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
