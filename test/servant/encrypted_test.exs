defmodule Servant.EncryptedTest do
  use ExUnit.Case, async: true

  alias Servant.Encrypted
  alias Servant.Encrypted.Map, as: EncMap

  test "round-trips a plaintext" do
    ct = Encrypted.encrypt("hello")
    assert Encrypted.encrypted?(ct)
    assert {:ok, "hello"} = Encrypted.decrypt(ct)
  end

  test "uses a fresh IV each time (same input -> different ciphertext)" do
    refute Encrypted.encrypt("x") == Encrypted.encrypt("x")
  end

  test "rejects garbage and tampered ciphertext" do
    assert :error = Encrypted.decrypt("not encrypted at all")

    <<"ENC1", rest::binary>> = Encrypted.encrypt("secret")
    tampered = "ENC1" <> :binary.copy(<<0>>, byte_size(rest))
    assert :error = Encrypted.decrypt(tampered)
  end

  test "encrypted?/1 distinguishes ciphertext from plaintext JSON" do
    assert Encrypted.encrypted?(Encrypted.encrypt("a"))
    refute Encrypted.encrypted?(~s({"a":1}))
  end

  describe "Encrypted.Map Ecto type" do
    test "dump then load round-trips a map" do
      {:ok, dumped} = EncMap.dump(%{"k" => "v", "n" => 1})
      assert Encrypted.encrypted?(dumped)
      assert {:ok, %{"k" => "v", "n" => 1}} = EncMap.load(dumped)
    end

    test "loads legacy plaintext JSON (backward compatibility)" do
      assert {:ok, %{"a" => 1}} = EncMap.load(~s({"a":1}))
    end

    test "load nil -> empty map" do
      assert {:ok, %{}} = EncMap.load(nil)
    end

    test "cast accepts maps and nil, and refuses the rest" do
      assert {:ok, %{"a" => 1}} = EncMap.cast(%{"a" => 1})
      assert {:ok, %{}} = EncMap.cast(nil)
      assert :error = EncMap.cast("a string")
      assert :error = EncMap.cast(42)
      assert :error = EncMap.cast(["a", "list"])
    end

    test "dump refuses anything that is not a map" do
      assert {:ok, nil} = EncMap.dump(nil)
      assert :error = EncMap.dump("plain")
      assert :error = EncMap.dump(42)
    end

    # A row that is neither ciphertext nor valid JSON must fail loudly. It must
    # not load silently as an empty config.
    test "load refuses a row that is neither ciphertext nor JSON" do
      assert :error = EncMap.load("not json, not encrypted")
      assert :error = EncMap.load(~s({"unterminated":))
    end

    test "the column type is a binary" do
      assert EncMap.type() == :binary
    end

    test "nested structures survive the round trip" do
      config = %{
        "accounts" => [%{"uid" => "a1", "name" => "CCP"}],
        "cursors" => %{"a1" => "2026-07-10"},
        "enabled" => true,
        "count" => 3
      }

      {:ok, dumped} = EncMap.dump(config)
      assert {:ok, ^config} = EncMap.load(dumped)
    end
  end
end
