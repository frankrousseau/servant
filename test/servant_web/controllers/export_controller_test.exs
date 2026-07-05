defmodule ServantWeb.ExportControllerTest do
  use ServantWeb.ConnCase

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  describe "entries (JSON)" do
    test "returns the caller's entries as a downloadable JSON attachment", %{
      conn: conn,
      user: user
    } do
      entry_fixture(user.id, %{"title" => "Exported"})
      other = user_fixture()
      entry_fixture(other.id, %{"title" => "Not mine"})

      conn = get(conn, "/api/export/entries")

      assert response_content_type(conn, :json)
      assert hd(get_resp_header(conn, "content-disposition")) =~ "attachment"
      data = json_response(conn, 200)
      titles = Enum.map(data, & &1["title"])
      assert "Exported" in titles
      refute "Not mine" in titles
    end
  end

  describe "ical" do
    test "returns a VCALENDAR with the user's events", %{conn: conn, user: user} do
      entry_fixture(user.id, %{
        "kind" => "event",
        "source" => "manual",
        "title" => "Launch",
        "data" => %{"location" => "Paris"}
      })

      conn = get(conn, "/api/export/entries.ics")

      assert hd(get_resp_header(conn, "content-type")) =~ "text/calendar"
      body = response(conn, 200)
      assert body =~ "BEGIN:VCALENDAR"
      assert body =~ "BEGIN:VEVENT"
      assert body =~ "SUMMARY:Launch"
      assert body =~ "LOCATION:Paris"
      assert body =~ "END:VCALENDAR"
    end

    test "escapes special characters in event fields", %{conn: conn, user: user} do
      entry_fixture(user.id, %{
        "kind" => "event",
        "source" => "manual",
        "title" => "A, B; C",
        "data" => %{"description" => "line1\nline2"}
      })

      conn = get(conn, "/api/export/entries.ics")
      body = response(conn, 200)

      assert body =~ "SUMMARY:A\\, B\\; C"
      assert body =~ "DESCRIPTION:line1\\nline2"
    end
  end
end
