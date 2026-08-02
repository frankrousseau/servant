defmodule Servant.StorageTest do
  use ExUnit.Case, async: false

  alias Servant.Storage

  setup do
    dir =
      Path.join(System.tmp_dir!(), "servant_storage_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    prev = System.get_env("FILES_DIR")
    System.put_env("FILES_DIR", dir)

    on_exit(fn ->
      if prev, do: System.put_env("FILES_DIR", prev), else: System.delete_env("FILES_DIR")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  describe "resolve_public_path/1 path traversal" do
    test "rejects parent-directory traversal" do
      assert Storage.resolve_public_path("../../etc/passwd") == :error
      assert Storage.resolve_public_path("foo/../../bar") == :error
    end

    test "rejects URL-encoded traversal" do
      assert Storage.resolve_public_path("..%2F..%2Fetc%2Fpasswd") == :error
    end

    test "returns :error for a safe but non-existent path" do
      assert Storage.resolve_public_path("u1/apps/files/missing.txt") == :error
    end

    test "resolves an existing file under files_root", %{dir: dir} do
      rel = "u1/apps/files/hello.txt"
      abs = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, "hi")

      assert {:ok, ^abs} = Storage.resolve_public_path(rel)
    end
  end

  describe "delete_public_file/2 ownership scoping" do
    setup %{dir: dir} do
      write = fn owner ->
        rel = "#{owner}/apps/files/doc.txt"
        abs = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, "data")
        {rel, abs}
      end

      %{write: write}
    end

    test "deletes a file owned by the caller", %{write: write} do
      {rel, abs} = write.("owner1")
      assert Storage.delete_public_file("owner1", "/files/#{rel}") == :ok
      refute File.exists?(abs)
    end

    test "refuses to delete another user's file", %{write: write} do
      {rel, abs} = write.("owner1")
      assert Storage.delete_public_file("attacker", "/files/#{rel}") == :ok
      assert File.exists?(abs)
    end
  end
end
