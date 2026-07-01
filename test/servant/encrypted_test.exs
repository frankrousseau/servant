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
  end
end
