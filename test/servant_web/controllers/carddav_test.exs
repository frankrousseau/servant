defmodule ServantWeb.CardDAVTest do
  @moduledoc "CardDAV half of ServantWeb.DavController. CalDAV has its own suite."

  use ServantWeb.ConnCase, async: false

  alias Servant.Data

  @vcf """
  BEGIN:VCARD
  VERSION:3.0
  UID:card-uid-1
  FN:Jeanne Dupont
  N:Dupont;Jeanne;;;
  EMAIL;TYPE=WORK:jeanne@example.com
  TEL;TYPE=CELL:+33600000000
  END:VCARD
  """

  defp basic_setup(conn, scopes \\ ["app:contacts:write"]) do
    user = user_fixture()

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{"name" => "phone", "scopes" => scopes})

    auth = put_req_header(conn, "authorization", "Basic " <> Base.encode64("f:#{plaintext}"))
    {auth, user}
  end

  defp dav(conn, method, path, body \\ "") do
    conn
    |> put_req_header("content-type", "application/xml")
    |> dispatch(@endpoint, method, path, body)
  end

  test "well-known carddav redirects to /dav", %{conn: conn} do
    conn = dav(conn, "PROPFIND", "/.well-known/carddav")

    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["/dav"]
  end

  test "principal advertises the addressbook home set", %{conn: conn} do
    {conn, user} = basic_setup(conn)

    principal = dav(conn, "PROPFIND", "/dav/principals/#{user.id}")
    assert response(principal, 207) =~ "/dav/addressbooks/#{user.id}/"
  end

  test "home lists the contacts collection with a ctag", %{conn: conn} do
    {conn, user} = basic_setup(conn)

    home =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/addressbooks/#{user.id}")

    body = response(home, 207)
    assert body =~ "/dav/addressbooks/#{user.id}/contacts/"
    assert body =~ "card:addressbook"
    assert body =~ "getctag"
  end

  test "PUT creates a contact entry, GET round-trips the raw vCard", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/addressbooks/#{user.id}/contacts/card-uid-1.vcf"

    put_conn = dav(conn, "PUT", path, @vcf)
    assert put_conn.status == 201
    assert [etag] = get_resp_header(put_conn, "etag")

    [entry] = Data.all_entries(user.id, %{"kind" => "contact"})
    assert entry.source == "carddav"
    assert entry.external_id == "card-uid-1"
    assert entry.title == "Jeanne Dupont - jeanne@example.com"
    assert entry.data["display_name"] == "Jeanne Dupont"
    assert entry.data["phones"] == [%{"value" => "+33600000000", "type" => "cell"}]

    get_conn = dav(conn, "GET", path)
    assert response(get_conn, 200) == @vcf
    assert get_resp_header(get_conn, "etag") == [etag]
  end

  test "PUT to an existing resource updates in place", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/addressbooks/#{user.id}/contacts/card-uid-1.vcf"

    assert dav(conn, "PUT", path, @vcf).status == 201

    updated = String.replace(@vcf, "FN:Jeanne Dupont", "FN:Jeanne Dupont-Martin")
    assert dav(conn, "PUT", path, updated).status == 204

    [entry] = Data.all_entries(user.id, %{"kind" => "contact"})
    assert entry.data["display_name"] == "Jeanne Dupont-Martin"
  end

  test "PUT whose UID matches an app contact updates it instead of duplicating",
       %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, imported} =
      Data.create_entry(user.id, %{
        "kind" => "contact",
        "source" => "manual",
        "external_id" => "card-uid-1",
        "title" => "Jeanne",
        "data" => %{"display_name" => "Jeanne"}
      })

    put_conn = dav(conn, "PUT", "/dav/addressbooks/#{user.id}/contacts/phone-name.vcf", @vcf)
    assert put_conn.status == 204

    [entry] = Data.all_entries(user.id, %{"kind" => "contact"})
    assert entry.id == imported.id
    assert entry.data["carddav_filename"] == "phone-name.vcf"
    assert entry.data["display_name"] == "Jeanne Dupont"
  end

  test "PUT with the synthesized <id>@servant UID under a new name finds the contact",
       %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, manual} =
      Data.create_entry(user.id, %{
        "kind" => "contact",
        "source" => "manual",
        "title" => "Paul Martin",
        "data" => %{"display_name" => "Paul Martin"}
      })

    vcf = String.replace(@vcf, "UID:card-uid-1", "UID:#{manual.id}@servant")
    put_conn = dav(conn, "PUT", "/dav/addressbooks/#{user.id}/contacts/renamed.vcf", vcf)
    assert put_conn.status == 204
    assert [%{id: id}] = Data.all_entries(user.id, %{"kind" => "contact"})
    assert id == manual.id
  end

  test "DELETE removes the contact", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/addressbooks/#{user.id}/contacts/card-uid-1.vcf"
    assert dav(conn, "PUT", path, @vcf).status == 201

    assert dav(conn, "DELETE", path).status == 204
    assert Data.all_entries(user.id, %{"kind" => "contact"}) == []
  end

  test "listing and multiget expose app-created contacts, not connector ones",
       %{conn: conn} do
    {conn, user} = basic_setup(conn)

    {:ok, manual} =
      Data.create_entry(user.id, %{
        "kind" => "contact",
        "source" => "manual",
        "title" => "Paul Martin",
        "data" => %{"display_name" => "Paul Martin", "emails" => [], "phones" => []}
      })

    {:ok, synced} =
      Data.create_entry(user.id, %{
        "kind" => "contact",
        "source" => "vcard",
        "title" => "Importé",
        "data" => %{"display_name" => "Importé"}
      })

    listing =
      conn
      |> put_req_header("depth", "1")
      |> dav("PROPFIND", "/dav/addressbooks/#{user.id}/contacts")

    body = response(listing, 207)
    assert body =~ "#{manual.id}.vcf"
    refute body =~ synced.id

    multiget = """
    <?xml version="1.0" encoding="utf-8"?>
    <card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop><d:getetag/><card:address-data/></d:prop>
      <d:href>/dav/addressbooks/#{user.id}/contacts/#{manual.id}.vcf</d:href>
    </card:addressbook-multiget>
    """

    report = dav(conn, "REPORT", "/dav/addressbooks/#{user.id}/contacts", multiget)
    report_body = response(report, 207)
    assert report_body =~ "FN:Paul Martin"
    assert report_body =~ "address-data"
  end

  test "addressbook-query returns the whole collection", %{conn: conn} do
    {conn, user} = basic_setup(conn)
    path = "/dav/addressbooks/#{user.id}/contacts/card-uid-1.vcf"
    assert dav(conn, "PUT", path, @vcf).status == 201

    query = """
    <?xml version="1.0" encoding="utf-8"?>
    <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop><d:getetag/><card:address-data/></d:prop>
    </card:addressbook-query>
    """

    report = dav(conn, "REPORT", "/dav/addressbooks/#{user.id}/contacts", query)
    assert response(report, 207) =~ "FN:Jeanne Dupont"
  end

  test "calendar-scoped tokens cannot touch the address book and vice versa",
       %{conn: conn} do
    {conn, user} = basic_setup(conn, ["app:calendar:write"])

    assert dav(conn, "PROPFIND", "/dav/addressbooks/#{user.id}").status == 403

    put = dav(conn, "PUT", "/dav/addressbooks/#{user.id}/contacts/x.vcf", @vcf)
    assert put.status == 403

    # A contacts token can still discover the shared principal.
    {contacts_conn, user2} = basic_setup(build_conn(), ["app:contacts:read"])
    assert dav(contacts_conn, "PROPFIND", "/dav/principals/#{user2.id}").status == 207
    assert dav(contacts_conn, "PROPFIND", "/dav/calendars/#{user2.id}").status == 403
  end
end
