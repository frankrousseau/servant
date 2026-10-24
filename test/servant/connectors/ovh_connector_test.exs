defmodule Servant.Connectors.OvhConnectorTest do
  use Servant.DataCase

  alias Servant.Connectors.OvhConnector
  alias Servant.Data

  @config %{
    "application_key" => "app-key",
    "application_secret" => "app-secret",
    "consumer_key" => "consumer-key"
  }

  describe "init/2" do
    test "requires the three OVH API keys" do
      assert OvhConnector.init(%{}, %{}) == {:error, :missing_application_key}

      assert OvhConnector.init(%{}, Map.delete(@config, "consumer_key")) ==
               {:error, :missing_consumer_key}

      assert OvhConnector.init(%{}, Map.put(@config, "application_secret", "  ")) ==
               {:error, :missing_application_secret}
    end

    test "defaults to the EU endpoint and trims pasted keys" do
      config = Map.put(@config, "application_key", " app-key\n")

      assert {:ok, state} = OvhConnector.init(%{}, config)
      assert state.app_key == "app-key"
      assert state.endpoint == "https://eu.api.ovh.com/1.0"
    end

    test "accepts a custom endpoint and drops its trailing slash" do
      config = Map.put(@config, "endpoint", "https://ca.api.ovh.com/1.0/")

      assert {:ok, state} = OvhConnector.init(%{}, config)
      assert state.endpoint == "https://ca.api.ovh.com/1.0"
    end

    test "an empty endpoint field falls back to the default" do
      assert {:ok, state} = OvhConnector.init(%{}, Map.put(@config, "endpoint", ""))
      assert state.endpoint == "https://eu.api.ovh.com/1.0"
    end
  end

  describe "signature/6" do
    test "signs the request the way OVH expects" do
      # The vector is locked so that a later change in the order of the joined
      # fields cannot pass.
      signature =
        OvhConnector.signature(
          "app-secret",
          "consumer-key",
          "GET",
          "https://eu.api.ovh.com/1.0/me/bill",
          "",
          1_366_560_945
        )

      assert signature == "$1$6aaf4d948daaecfb0f4d3dc31e3134584fccac1b"
    end
  end

  describe "build_entry/1" do
    test "maps a bill onto the invoice entry shape the scraper used" do
      bill = %{
        "billId" => "FR12345678",
        "date" => "2026-08-15T09:34:12+02:00",
        "priceWithTax" => %{
          "currencyCode" => "EUR",
          "text" => "10.99 €",
          "value" => 10.99
        },
        "pdfUrl" => "https://www.ovh.com/bill.pdf"
      }

      entry = OvhConnector.build_entry(bill)

      assert entry["kind"] == "invoice"
      assert entry["source"] == "ovh"
      assert entry["external_id"] == "ovh-FR12345678"
      assert entry["title"] == "OVH - 10.99 € (August 2026)"
      assert entry["occurred_at"] == ~U[2026-08-15 07:34:12Z]
      assert entry["data"]["amount"] == "10.99"
      assert entry["data"]["currency"] == "EUR"
      assert entry["data"]["url"] == "https://www.ovh.com/bill.pdf"
    end

    test "survives a bill with no price and a date-only date" do
      entry = OvhConnector.build_entry(%{"billId" => "FR1", "date" => "2026-07-01"})

      assert entry["external_id"] == "ovh-FR1"
      assert entry["title"] == "OVH - 0 EUR (July 2026)"
      assert entry["occurred_at"] == ~U[2026-07-01 00:00:00Z]
    end

    test "points at the stored PDF when there is one, keeping the remote link" do
      bill = %{"billId" => "FR1", "date" => "2026-07-01", "pdfUrl" => "https://ovh/bill.pdf"}
      entry = OvhConnector.build_entry(bill, "/files/u1/apps/files/abc.pdf")

      assert entry["data"]["url"] == "/files/u1/apps/files/abc.pdf"
      assert entry["data"]["remote_url"] == "https://ovh/bill.pdf"
    end
  end

  describe "new_ids/2" do
    test "drops bills already imported before any detail fetch" do
      known = MapSet.new(["ovh-FR1", "ovh-FR2"])

      assert OvhConnector.new_ids(["FR1", "FR2", "FR3"], known) == ["FR3"]
    end
  end

  describe "pdf_filename/1" do
    test "names the file from the date and the bill id" do
      bill = %{"billId" => "FR12345678", "date" => "2026-08-15T09:34:12+02:00"}

      assert OvhConnector.pdf_filename(bill) == "ovh-2026-08-15-FR12345678.pdf"
    end

    test "copes with a dateless bill" do
      assert OvhConnector.pdf_filename(%{"billId" => "FR1"}) == "ovh-FR1.pdf"
    end
  end

  describe "metadata" do
    test "identifies as an on-demand-capable daily invoice connector" do
      assert OvhConnector.id() == "ovh"
      assert OvhConnector.kind() == "invoice"
      assert OvhConnector.default_schedule() == "every_day"
      assert "on_demand" in OvhConnector.supported_schedules()
    end
  end

  describe "sync/1" do
    @server_time 1_800_000_000

    defp bill(id, overrides \\ %{}) do
      Map.merge(
        %{
          "billId" => id,
          "date" => "2026-08-15T09:34:12+02:00",
          "priceWithTax" => %{"currencyCode" => "EUR", "text" => "10.99 €", "value" => 10.99},
          "pdfUrl" => "https://www.ovh.com/#{id}.pdf"
        },
        overrides
      )
    end

    # Routes the three calls that a sync makes: the clock, the bill list, one
    # detail for each bill. It also routes the PDF download, which is on a
    # different host.
    defp stub_ovh(bills, opts \\ []) do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/1.0/auth/time" ->
            Req.Test.json(conn, Keyword.get(opts, :time, @server_time))

          "/1.0/me/bill" ->
            Req.Test.json(conn, Enum.map(bills, & &1["billId"]))

          "/1.0/me/bill/" <> id ->
            Req.Test.json(conn, Enum.find(bills, &(&1["billId"] == id)))

          _ ->
            Plug.Conn.send_resp(conn, 200, Keyword.get(opts, :pdf, "%PDF-1.4 fake"))
        end
      end)
    end

    defp state(config \\ %{}) do
      {:ok, state} = OvhConnector.init(%{}, Map.merge(@config, config))
      state
    end

    test "signs every call with the server's clock, not ours" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/1.0/auth/time" ->
            Req.Test.json(conn, @server_time)

          "/1.0/me/bill" ->
            [timestamp] = Plug.Conn.get_req_header(conn, "x-ovh-timestamp")
            assert abs(String.to_integer(timestamp) - @server_time) <= 2

            assert Plug.Conn.get_req_header(conn, "x-ovh-application") == ["app-key"]
            assert Plug.Conn.get_req_header(conn, "x-ovh-consumer") == ["consumer-key"]

            expected =
              OvhConnector.signature(
                "app-secret",
                "consumer-key",
                "GET",
                "https://eu.api.ovh.com/1.0/me/bill",
                "",
                String.to_integer(timestamp)
              )

            assert Plug.Conn.get_req_header(conn, "x-ovh-signature") == [expected]
            Req.Test.json(conn, [])
        end
      end)

      assert {:ok, [], _state} = OvhConnector.sync(state())
    end

    test "turns each new bill into an invoice entry" do
      stub_ovh([bill("FR1"), bill("FR2")])

      assert {:ok, entries, _state} = OvhConnector.sync(state())

      assert Enum.map(entries, & &1["external_id"]) == ["ovh-FR2", "ovh-FR1"]
      assert hd(entries)["kind"] == "invoice"
      # Without a user_id, there is no local PDF. The entry keeps the link from OVH.
      assert hd(entries)["data"]["url"] == "https://www.ovh.com/FR2.pdf"
    end

    test "reads a clock served as text" do
      stub_ovh([], time: to_string(@server_time))
      assert {:ok, [], _state} = OvhConnector.sync(state())
    end

    test "an unreadable clock fails the sync" do
      stub_ovh([], time: "not a timestamp")
      assert {:error, message, _state} = OvhConnector.sync(state())
      assert message =~ "unreadable clock"
    end

    test "a clock endpoint that errors fails the sync" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, message, _state} = OvhConnector.sync(state())
      assert message =~ "HTTP 503"
    end

    test "an unexpected bill list is reported" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/1.0/auth/time" -> Req.Test.json(conn, @server_time)
          "/1.0/me/bill" -> Req.Test.json(conn, %{"message" => "nope"})
        end
      end)

      assert {:error, message, _state} = OvhConnector.sync(state())
      assert message =~ "unexpected /me/bill payload"
    end

    test "a failing bill detail surfaces OVH's message" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/1.0/auth/time" ->
            Req.Test.json(conn, @server_time)

          "/1.0/me/bill" ->
            Req.Test.json(conn, ["FR1"])

          "/1.0/me/bill/FR1" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              403,
              Jason.encode!(%{"message" => "This call has not been granted"})
            )
        end
      end)

      assert {:error, message, _state} = OvhConnector.sync(state())
      assert message =~ "HTTP 403: This call has not been granted"
    end

    test "an already-imported bill is never fetched again" do
      user = user_fixture()

      {:ok, _entry} =
        Data.create_entry(user.id, %{
          kind: "invoice",
          source: "ovh",
          external_id: "ovh-FR1",
          title: "OVH - old"
        })

      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/1.0/auth/time" -> Req.Test.json(conn, @server_time)
          "/1.0/me/bill" -> Req.Test.json(conn, ["FR1", "FR2"])
          "/1.0/me/bill/FR1" -> flunk("FR1 was already imported")
          "/1.0/me/bill/FR2" -> Req.Test.json(conn, bill("FR2"))
          _ -> Plug.Conn.send_resp(conn, 404, "no pdf")
        end
      end)

      assert {:ok, entries, _state} = OvhConnector.sync(state(%{"user_id" => user.id}))
      assert Enum.map(entries, & &1["external_id"]) == ["ovh-FR2"]
    end
  end

  describe "sync/1 with file storage" do
    setup do
      base = Path.join(System.tmp_dir!(), "ovh_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      previous = {System.get_env("FILES_DIR"), System.get_env("TMP_DIR")}
      System.put_env("FILES_DIR", Path.join(base, "files"))
      System.put_env("TMP_DIR", Path.join(base, "tmp"))

      on_exit(fn ->
        {files, tmp} = previous
        restore_env("FILES_DIR", files)
        restore_env("TMP_DIR", tmp)
        File.rm_rf(base)
      end)

      %{user: user_fixture()}
    end

    defp restore_env(key, nil), do: System.delete_env(key)
    defp restore_env(key, value), do: System.put_env(key, value)

    test "stores the PDF, files it under Invoices and links the entry to it", %{user: user} do
      {:ok, state} = OvhConnector.init(%{}, Map.put(@config, "user_id", user.id))
      stub_ovh([bill("FR1")])

      assert {:ok, [invoice, file], _state} = OvhConnector.sync(state)

      assert invoice["kind"] == "invoice"
      assert String.starts_with?(invoice["data"]["url"], "/files/")
      assert invoice["data"]["remote_url"] == "https://www.ovh.com/FR1.pdf"

      assert file["kind"] == "file"
      assert file["title"] == "ovh-2026-08-15-FR1.pdf"
      assert file["data"]["mime_type"] == "application/pdf"
      assert file["data"]["size"] == byte_size("%PDF-1.4 fake")

      # The connector creates the shared root folder one time and files the PDF
      # under it.
      folder = Enum.find(Data.all_entries(user.id, %{"kind" => "file"}), & &1.data["is_folder"])
      assert folder.data["filename"] == "Invoices"
      assert file["data"]["parent_id"] == folder.id
    end

    test "a PDF that cannot be downloaded still yields the invoice", %{user: user} do
      {:ok, state} = OvhConnector.init(%{}, Map.put(@config, "user_id", user.id))

      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/1.0/auth/time" -> Req.Test.json(conn, @server_time)
          "/1.0/me/bill" -> Req.Test.json(conn, ["FR1"])
          "/1.0/me/bill/FR1" -> Req.Test.json(conn, bill("FR1"))
          _ -> Plug.Conn.send_resp(conn, 404, "gone")
        end
      end)

      assert {:ok, [invoice], _state} = OvhConnector.sync(state)
      assert invoice["data"]["url"] == "https://www.ovh.com/FR1.pdf"
    end
  end
end
