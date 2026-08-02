defmodule Servant.HTTPTest do
  use ExUnit.Case, async: true

  alias Servant.HTTP

  describe "ensure_public_url/1" do
    test "allows public IPv4/IPv6 literals" do
      assert HTTP.ensure_public_url("http://93.184.216.34/feed") == :ok
      assert HTTP.ensure_public_url("https://8.8.8.8/") == :ok
    end

    test "blocks loopback" do
      assert HTTP.ensure_public_url("http://127.0.0.1/x") == {:error, :blocked_url}
      assert HTTP.ensure_public_url("http://[::1]/x") == {:error, :blocked_url}
    end

    test "blocks the cloud metadata endpoint and link-local" do
      assert HTTP.ensure_public_url("http://169.254.169.254/latest/meta-data") ==
               {:error, :blocked_url}
    end

    test "blocks private ranges" do
      assert HTTP.ensure_public_url("http://10.0.0.5/") == {:error, :blocked_url}
      assert HTTP.ensure_public_url("http://172.16.3.4/") == {:error, :blocked_url}
      assert HTTP.ensure_public_url("http://192.168.1.1/") == {:error, :blocked_url}
    end

    test "blocks non-http(s) schemes" do
      assert HTTP.ensure_public_url("ftp://example.com/") == {:error, :blocked_url}
      assert HTTP.ensure_public_url("file:///etc/passwd") == {:error, :blocked_url}
    end

    test "blocks garbage input" do
      assert HTTP.ensure_public_url("not a url") == {:error, :blocked_url}
      assert HTTP.ensure_public_url(nil) == {:error, :blocked_url}
    end
  end
end
