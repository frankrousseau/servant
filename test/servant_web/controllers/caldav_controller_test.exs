defmodule ServantWeb.CalDAVControllerTest do
  use ServantWeb.ConnCase, async: false

  alias Servant.Data

  @ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Apple Inc.//iOS 19.0//EN
  BEGIN:VEVENT
  UID:phone-uid-1
  DTSTAMP:20260713T120000Z
  DTSTART;TZID=Europe/Paris:20260715T100000
  DTEND;TZID=Europe/Paris:20260715T110000
  SUMMARY:Dentiste
  END:VEVENT
  END:VCALENDAR
  """

  defp basic_setup(conn, scopes \\ ["app:calendar:write"]) do
    user = user_fixture()

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{"name" => "phone", "scopes" => scopes})

    {with_basic(conn, plaintext), user}
  end

  defp with_basic(conn, password) do
    put_req_header(conn, "authorization", "Basic " <> Base.encode64("frank:#{password}"))
  end

  defp dav(conn, method, path, body \\ "") do
    conn
    |> put_req_header("content-type", "application/xml")
    |> dispatch(@endpoint, method, path, body)
  end

  test "requests without credentials get a Basic challenge", %{conn: conn} do
    conn = dav(conn, "PROPFIND", "/dav")

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Servant CalDAV")]
  end

  test "well-known redirects to /dav", %{conn: conn} do
    conn = dav(conn, "PROPFIND", "/.well-known/caldav")

    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["/dav"]
  end

  test "session tokens work as Basic password", %{conn: conn} do
    user = user_fixture()
    token = ServantWeb.Auth.sign_token(ServantWeb.Endpoint, user)
    conn = conn |> with_basic(token) |> dav("PROPFIND", "/dav")

    assert conn.status == 207
  end

  test "discovery chain: principal, home set, collections", %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, _} =
      Data.create_entry(user.id, %{
        "kind" => "calendar",
        "source" => "calendar_app",
        "title" => "Perso"
      })

    root = dav(conn, "PROPFIND", "/dav")
    assert root.status == 207
    assert response(root, 207) =~ "/dav/principals/#{user.id}/"

    principal = dav(conn, "PROPFIND", "/dav/principals/#{user.id}")
    assert response(principal, 207) =~ "/dav/calendars/#{user.id}/"

    home =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/calendars/#{user.id}")

    body = response(home, 207)
    assert body =~ "Manual"
    assert body =~ "Perso"
    assert body =~ "getctag"
  end

  test "agendas referenced only by events become collections too", %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, _} =
      Data.create_entry(user.id, %{
        "kind" => "event",
        "source" => "manual",
        "title" => "Yoga",
        "occurred_at" => "2026-07-20T18:00:00Z",
        "data" => %{"calendar" => "Sport", "summary" => "Yoga"}
      })

    home =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/calendars/#{user.id}")

    assert response(home, 207) =~ "Sport"

    listing =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/calendars/#{user.id}/Sport")

    assert response(listing, 207) =~ ".ics"

    report =
      dav(conn, "REPORT", "/dav/calendars/#{user.id}/Sport", """
      <?xml version="1.0" encoding="utf-8" ?>
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
      </c:calendar-query>
      """)

    assert response(report, 207) =~ "SUMMARY:Yoga"
  end

  test "another user's tree is a 404", %{conn: conn} do
    {conn, _user} = basic_setup(conn)
    other = user_fixture()

    assert conn |> dav("PROPFIND", "/dav/calendars/#{other.id}") |> response(404)
  end

  test "PUT creates an event entry, GET round-trips the raw ICS", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/calendars/#{user.id}/Manual/phone-uid-1.ics"

    put_conn = dav(conn, "PUT", path, @ics)
    assert put_conn.status == 201
    assert [etag] = get_resp_header(put_conn, "etag")

    [entry] = Data.all_entries(user.id, %{"kind" => "event"})
    assert entry.source == "caldav"
    assert entry.external_id == "phone-uid-1"
    assert entry.title == "Dentiste"
    assert entry.occurred_at == ~U[2026-07-15 08:00:00Z]
    assert entry.data["calendar"] == "Manual"

    get_conn = dav(conn, "GET", path)
    assert response(get_conn, 200) == @ics
    assert get_resp_header(get_conn, "etag") == [etag]
  end

  test "PUT to an existing resource updates in place", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/calendars/#{user.id}/Manual/phone-uid-1.ics"

    assert dav(conn, "PUT", path, @ics).status == 201

    updated = String.replace(@ics, "SUMMARY:Dentiste", "SUMMARY:Dentiste reporté")
    assert dav(conn, "PUT", path, updated).status == 204

    [entry] = Data.all_entries(user.id, %{"kind" => "event"})
    assert entry.title == "Dentiste reporté"
  end

  test "If-None-Match: * refuses to overwrite", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/calendars/#{user.id}/Manual/phone-uid-1.ics"
    assert dav(conn, "PUT", path, @ics).status == 201

    conflict =
      conn
      |> put_req_header("if-none-match", "*")
      |> dav("PUT", path, @ics)

    assert conflict.status == 412
  end

  test "DELETE removes the entry", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/calendars/#{user.id}/Manual/phone-uid-1.ics"
    assert dav(conn, "PUT", path, @ics).status == 201

    assert dav(conn, "DELETE", path).status == 204
    assert Data.all_entries(user.id, %{"kind" => "event"}) == []
    assert dav(conn, "GET", path).status == 404
  end

  test "collection listing and multiget REPORT include app-created events only",
       %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, manual} =
      Data.create_entry(user.id, %{
        "kind" => "event",
        "source" => "manual",
        "title" => "Réunion",
        "occurred_at" => "2026-07-20T09:00:00Z",
        "data" => %{"calendar" => "Manual", "end_at" => "2026-07-20T10:00:00Z"}
      })

    {:ok, synced} =
      Data.create_entry(user.id, %{
        "kind" => "event",
        "source" => "ical",
        "title" => "Depuis un connecteur",
        "occurred_at" => "2026-07-21T09:00:00Z"
      })

    listing =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/calendars/#{user.id}/Manual")

    body = response(listing, 207)
    assert body =~ "#{manual.id}.ics"
    refute body =~ synced.id

    multiget = """
    <?xml version="1.0" encoding="utf-8"?>
    <c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop><d:getetag/><c:calendar-data/></d:prop>
      <d:href>/dav/calendars/#{user.id}/Manual/#{manual.id}.ics</d:href>
    </c:calendar-multiget>
    """

    report = dav(conn, "REPORT", "/dav/calendars/#{user.id}/Manual", multiget)
    report_body = response(report, 207)
    assert report_body =~ "SUMMARY:Réunion"
    assert report_body =~ "DTSTART:20260720T090000Z"
  end

  test "calendar-query returns the whole collection", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/calendars/#{user.id}/Manual/phone-uid-1.ics"
    assert dav(conn, "PUT", path, @ics).status == 201

    query = """
    <?xml version="1.0" encoding="utf-8"?>
    <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop><d:getetag/><c:calendar-data/></d:prop>
    </c:calendar-query>
    """

    report = dav(conn, "REPORT", "/dav/calendars/#{user.id}/Manual", query)
    assert response(report, 207) =~ "SUMMARY:Dentiste"
  end

  test "read-only tokens cannot PUT or DELETE", %{conn: conn} do
    {conn, user} = basic_setup(conn, ["app:calendar:read"])
    path = "/dav/calendars/#{user.id}/Manual/phone-uid-1.ics"

    assert dav(conn, "PROPFIND", "/dav/calendars/#{user.id}").status == 207
    assert dav(conn, "PUT", path, @ics).status == 403
    assert dav(conn, "DELETE", path).status == 403
  end

  test "calendar names with spaces work URL-encoded", %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, _} =
      Data.create_entry(user.id, %{
        "kind" => "calendar",
        "source" => "calendar_app",
        "title" => "Vie perso"
      })

    home =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/calendars/#{user.id}")

    assert response(home, 207) =~ "/dav/calendars/#{user.id}/Vie%20perso/"

    path = "/dav/calendars/#{user.id}/Vie%20perso/phone-uid-1.ics"
    assert dav(conn, "PUT", path, @ics).status == 201

    [entry] = Data.all_entries(user.id, %{"kind" => "event"})
    assert entry.data["calendar"] == "Vie perso"
    assert dav(conn, "GET", path).status == 200
  end

  test "unknown calendars 404", %{conn: conn} do
    {conn, user} = basic_setup(conn)

    assert dav(conn, "PUT", "/dav/calendars/#{user.id}/Nope/x.ics", @ics).status == 404
  end

  test "OPTIONS advertises calendar-access", %{conn: conn} do
    {conn, _user} = basic_setup(conn)
    conn = dav(conn, "OPTIONS", "/dav")

    assert conn.status == 200
    assert [dav_header] = get_resp_header(conn, "dav")
    assert dav_header =~ "calendar-access"
  end
end
