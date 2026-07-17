defmodule Servant.AITest do
  use ExUnit.Case, async: true

  alias Servant.AI

  @config %{
    "base_url" => "http://localhost:9999/v1",
    "model" => "test-model",
    "api_key" => nil
  }

  @messages [%{role: "system", content: "s"}, %{role: "user", content: "u"}]

  test "posts to {base_url}/chat/completions and returns content and usage" do
    plug = fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["model"] == "test-model"
      assert payload["stream"] == false
      assert [%{"role" => "system"}, %{"role" => "user"}] = payload["messages"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "hello"}}],
        "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 34}
      })
    end

    assert {:ok, %{content: "hello", usage: usage}} = AI.chat(@config, @messages, plug: plug)
    assert usage == %{input_tokens: 12, output_tokens: 34}
  end

  test "sends a bearer header when a key is configured" do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-x"]
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end

    config = Map.put(@config, "api_key", "sk-x")
    assert {:ok, %{content: "ok", usage: nil}} = AI.chat(config, @messages, plug: plug)
  end

  test "returns an error on a non-200 status" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

    assert {:error, message} = AI.chat(@config, @messages, plug: plug)
    assert message =~ "HTTP 500"
  end

  test "returns an error on an unexpected body" do
    plug = fn conn -> Req.Test.json(conn, %{"weird" => true}) end

    assert {:error, message} = AI.chat(@config, @messages, plug: plug)
    assert message =~ "unexpected response"
  end
end
