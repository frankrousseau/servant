defmodule Servant.AppsTest do
  use Servant.DataCase

  import Servant.Fixtures

  alias Servant.Apps

  @manifest %{
    "id" => "todo-plus",
    "name" => "Todo Plus",
    "description" => "A fancier todo app",
    "icon" => "ListChecks",
    "entry" => "dist/index.js"
  }

  setup do
    user = user_fixture()

    on_exit(fn ->
      File.rm_rf(Servant.Storage.join_files([user.id]))
    end)

    %{user: user}
  end

  defp repo_fixture(manifest) do
    dir = Path.join(System.tmp_dir!(), "servant-app-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(dir, "dist"))
    File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "dist/index.js"), "export default { mount() {} }")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "install_from_dir/3" do
    test "installs a valid app and copies its files", %{user: user} do
      dir = repo_fixture(@manifest)

      assert {:ok, app} = Apps.install_from_dir(user.id, dir, "https://example.com/todo.git")
      assert app.app_id == "todo-plus"
      assert app.name == "Todo Plus"
      assert app.icon == "ListChecks"

      installed = Apps.install_dir(user.id, "todo-plus")
      assert File.regular?(Path.join(installed, "dist/index.js"))
      assert Apps.entry_url(app) == "/files/#{user.id}/installed_apps/todo-plus/dist/index.js"
    end

    test "rejects a missing or invalid manifest", %{user: user} do
      dir = Path.join(System.tmp_dir!(), "servant-app-#{Ecto.UUID.generate()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, msg} = Apps.install_from_dir(user.id, dir, "https://x")
      assert msg =~ "servant-app.json"
    end

    test "rejects reserved and malformed ids", %{user: user} do
      dir = repo_fixture(%{@manifest | "id" => "photos"})
      assert {:error, msg} = Apps.install_from_dir(user.id, dir, "https://x")
      assert msg =~ "reserved"

      dir = repo_fixture(%{@manifest | "id" => "Bad Id!"})
      assert {:error, msg} = Apps.install_from_dir(user.id, dir, "https://x")
      assert msg =~ "lowercase"
    end

    test "rejects an entry that escapes the repo or does not exist", %{user: user} do
      dir = repo_fixture(%{@manifest | "entry" => "../../etc/passwd.js"})
      assert {:error, msg} = Apps.install_from_dir(user.id, dir, "https://x")
      assert msg =~ "entry"

      dir = repo_fixture(%{@manifest | "entry" => "dist/missing.js"})
      assert {:error, _} = Apps.install_from_dir(user.id, dir, "https://x")
    end

    test "rejects a duplicate app id", %{user: user} do
      dir = repo_fixture(@manifest)
      assert {:ok, _} = Apps.install_from_dir(user.id, dir, "https://x")

      dir = repo_fixture(@manifest)
      assert {:error, msg} = Apps.install_from_dir(user.id, dir, "https://x")
      assert msg =~ "already installed"
    end
  end

  describe "install_from_git/2" do
    test "rejects non-https urls without cloning", %{user: user} do
      for url <- ["ext::sh -c whoami", "file:///etc", "git@github.com:a/b.git", ""] do
        assert {:error, msg} = Apps.install_from_git(user.id, url)
        assert msg =~ "https"
      end
    end
  end

  describe "uninstall/2" do
    test "removes the row and the files", %{user: user} do
      dir = repo_fixture(@manifest)
      {:ok, app} = Apps.install_from_dir(user.id, dir, "https://x")
      installed = Apps.install_dir(user.id, app.app_id)
      assert File.dir?(installed)

      assert Apps.uninstall(user.id, "todo-plus") == :ok
      assert Apps.list_apps(user.id) == []
      refute File.dir?(installed)
    end

    test "returns not_found for unknown apps", %{user: user} do
      assert Apps.uninstall(user.id, "nope") == {:error, :not_found}
    end
  end
end
