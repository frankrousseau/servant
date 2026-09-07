defmodule Servant.Connectors.EVM.ENSTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EVM.ENS

  test "resolves a name to its address" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      assert conn.request_path == "/ens/resolve/frank.eth"
      Req.Test.json(conn, %{"address" => "0xF00", "name" => "frank.eth"})
    end)

    assert ENS.resolve("frank.eth") == {:ok, "0xF00"}
  end

  test "percent-encodes the name in the URL" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      assert conn.request_path == "/ens/resolve/a%20b.eth"
      Req.Test.json(conn, %{"address" => "0xF00"})
    end)

    assert {:ok, _} = ENS.resolve("a b.eth")
  end

  test "an unregistered name resolves to nothing" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      Req.Test.json(conn, %{"address" => nil})
    end)

    assert ENS.resolve("nope.eth") == {:error, :ens_name_not_found}
  end

  test "a non-200 response carries the status" do
    Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "no") end)

    assert {:error, %{status: 404}} = ENS.resolve("nope.eth")
  end

  test "a transport error is returned as-is" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} = ENS.resolve("frank.eth")
  end
end
