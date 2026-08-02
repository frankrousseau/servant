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
end
