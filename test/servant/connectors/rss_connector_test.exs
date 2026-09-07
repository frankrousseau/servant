defmodule Servant.Connectors.RSSConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.RSSConnector

  describe "parse_pub_date/1" do
    test "parses RFC 822 pubDate with a numeric offset" do
      assert RSSConnector.parse_pub_date("Mon, 06 Sep 2021 16:45:00 +0000") ==
               ~U[2021-09-06 16:45:00Z]
    end

    test "converts a non-zero offset to UTC" do
      # 16:45 -0500 == 21:45 UTC
      assert RSSConnector.parse_pub_date("Mon, 06 Sep 2021 16:45:00 -0500") ==
               ~U[2021-09-06 21:45:00Z]
    end

    test "parses a named GMT zone as UTC" do
      assert RSSConnector.parse_pub_date("Wed, 02 Oct 2002 13:00:00 GMT") ==
               ~U[2002-10-02 13:00:00Z]
    end

    test "parses ISO 8601 (dc:date / Atom)" do
      assert RSSConnector.parse_pub_date("2021-09-06T16:45:00Z") == ~U[2021-09-06 16:45:00Z]
    end

    test "falls back to ~now for an unparseable date" do
      before = DateTime.utc_now()
      result = RSSConnector.parse_pub_date("not a date")
      assert DateTime.diff(result, before) >= -1
      assert DateTime.diff(result, before) <= 5
    end

    test "falls back to ~now when no date is given" do
      assert %DateTime{} = RSSConnector.parse_pub_date(nil)
    end
  end

  describe "external_id/1" do
    test "prefers the link" do
      assert RSSConnector.external_id(%{link: "https://x/1", title: "T", description: "d"}) ==
               "https://x/1"
    end

    test "falls back to the title when there is no link" do
      assert RSSConnector.external_id(%{link: nil, title: "T", description: "d"}) == "T"
    end

    test "falls back to a stable content hash when neither link nor title exist" do
      item = %{link: nil, title: nil, description: "body"}
      id = RSSConnector.external_id(item)
      assert String.starts_with?(id, "sha256:")
      # stable for the same content
      assert id == RSSConnector.external_id(item)
    end
  end

  describe "sync/1" do
    # A public IP literal, so the SSRF guard resolves without a DNS lookup and
    # the test stays offline; Req.Test answers the request itself.
    @feed_url "http://93.184.216.34/feed.xml"

    @rss """
    <?xml version="1.0"?>
    <rss version="2.0"><channel>
      <title>Feed</title>
      <item>
        <title>First post</title>
        <link>https://blog.test/first</link>
        <description><![CDATA[Hello <b>world</b>]]></description>
        <pubDate>Tue, 01 Jul 2026 10:00:00 +0000</pubDate>
      </item>
      <item>
        <title>Second post</title>
        <link>https://blog.test/second</link>
        <description>Plain text</description>
        <pubDate>Wed, 02 Jul 2026 12:30:00 +0200</pubDate>
      </item>
    </channel></rss>
    """

    defp stub_feed(body, status \\ 200) do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, status, body) end)
    end

    test "turns feed items into article entries" do
      stub_feed(@rss)
      {:ok, state} = RSSConnector.init(%{}, %{"url" => @feed_url})

      assert {:ok, [first, second], ^state} = RSSConnector.sync(state)

      assert first["kind"] == "article"
      assert first["source"] == "rss"
      assert first["title"] == "First post"
      assert first["external_id"] == "https://blog.test/first"
      assert first["occurred_at"] == ~U[2026-07-01 10:00:00Z]
      assert first["data"]["description"] == "Hello <b>world</b>"
      assert first["metadata"]["feed_url"] == @feed_url

      assert second["occurred_at"] == ~U[2026-07-02 10:30:00Z]
    end

    test "an empty feed yields no entries" do
      stub_feed("<rss><channel><title>Nothing</title></channel></rss>")
      {:ok, state} = RSSConnector.init(%{}, %{"url" => @feed_url})

      assert {:ok, [], ^state} = RSSConnector.sync(state)
    end

    test "a non-200 response fails the sync" do
      stub_feed("gone", 404)
      {:ok, state} = RSSConnector.init(%{}, %{"url" => @feed_url})

      assert {:error, "HTTP 404", ^state} = RSSConnector.sync(state)
    end

    # The feed URL comes from the user, so it must never be usable to reach
    # the host's own network (SSRF).
    test "refuses a URL that is not publicly routable" do
      Req.Test.stub(Servant.HTTP, fn _conn -> flunk("the guard should have refused") end)

      for url <- [
            "http://localhost:4000/feed",
            "http://127.0.0.1/feed",
            "http://169.254.169.254/latest/meta-data/",
            "http://192.168.1.10/feed",
            "file:///etc/passwd"
          ] do
        {:ok, state} = RSSConnector.init(%{}, %{"url" => url})
        assert {:error, "Refusing to fetch a non-public URL", ^state} = RSSConnector.sync(state)
      end
    end
  end
end
