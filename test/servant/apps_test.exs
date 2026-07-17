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

  describe "update_from_dir/2" do
    test "replaces files and refreshes manifest metadata", %{user: user} do
      dir = repo_fixture(@manifest)
      {:ok, app} = Apps.install_from_dir(user.id, dir, "https://example.com/todo.git")

      new_dir = repo_fixture(%{@manifest | "name" => "Todo Plus v2", "entry" => "app.js"})
      File.write!(Path.join(new_dir, "app.js"), "export default { mount() { /* v2 */ } }")

      assert {:ok, updated} = Apps.update_from_dir(app, new_dir)
      assert updated.name == "Todo Plus v2"
      assert updated.entry == "app.js"
      assert updated.repo_url == "https://example.com/todo.git"

      installed = Apps.install_dir(user.id, "todo-plus")
      assert File.regular?(Path.join(installed, "app.js"))
      assert Apps.entry_url(updated) == "/files/#{user.id}/installed_apps/todo-plus/app.js"
    end

    test "rejects a manifest whose id changed", %{user: user} do
      dir = repo_fixture(@manifest)
      {:ok, app} = Apps.install_from_dir(user.id, dir, "https://x")

      new_dir = repo_fixture(%{@manifest | "id" => "other-app"})
      assert {:error, msg} = Apps.update_from_dir(app, new_dir)
      assert msg =~ "id changed"
    end
  end

  describe "update_from_git/2" do
    test "returns not_found for unknown apps", %{user: user} do
      assert Apps.update_from_git(user.id, "nope") == {:error, :not_found}
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

  defp install_generated(user_id, app_id, code) do
    dir = Path.join(System.tmp_dir!(), "servant-app-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.js"), code)

    manifest = %{"id" => app_id, "name" => "Gen App", "entry" => "index.js"}
    File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, app} = Apps.install_from_dir(user_id, dir, nil)
    app
  end

  describe "generated apps" do
    test "install_from_dir accepts a nil repo_url and marks the app generated", %{user: user} do
      app = install_generated(user.id, "gen-todo", "export default {}")

      assert app.repo_url == nil
      assert Apps.generated?(app)
      refute Apps.previous_version?(app)
    end

    test "a git app is not generated", %{user: user} do
      dir = repo_fixture(@manifest)
      {:ok, app} = Apps.install_from_dir(user.id, dir, "https://example.com/todo.git")

      refute Apps.generated?(app)
    end

    test "restore_previous swaps the entry with index.prev.js and bumps updated_at", %{
      user: user
    } do
      app = install_generated(user.id, "gen-todo", "// v2")

      dir = Apps.install_dir(user.id, "gen-todo")
      File.write!(Path.join(dir, "index.prev.js"), "// v1")

      assert Apps.previous_version?(app)
      {:ok, restored} = Apps.restore_previous(user.id, "gen-todo")

      assert File.read!(Path.join(dir, "index.js")) == "// v1"
      assert File.read!(Path.join(dir, "index.prev.js")) == "// v2"
      assert DateTime.compare(restored.updated_at, app.updated_at) in [:gt, :eq]
    end

    test "restore_previous without a previous version fails", %{user: user} do
      install_generated(user.id, "gen-todo", "// only")

      assert {:error, message} = Apps.restore_previous(user.id, "gen-todo")
      assert message =~ "previous"
    end

    test "restore_previous refuses git apps and unknown apps", %{user: user} do
      assert Apps.restore_previous(user.id, "nope") == {:error, :not_found}

      dir = repo_fixture(@manifest)
      {:ok, app} = Apps.install_from_dir(user.id, dir, "https://example.com/todo.git")

      assert {:error, message} = Apps.restore_previous(user.id, app.app_id)
      assert message =~ "generated"
    end

    test "update_from_git refuses generated apps", %{user: user} do
      app = install_generated(user.id, "gen-todo", "export default {}")

      assert {:error, message} = Apps.update_from_git(user.id, app.app_id)
      assert message =~ "git repository"
    end

    test "update_from_dir bumps updated_at even when the manifest is unchanged", %{user: user} do
      app = install_generated(user.id, "gen-todo", "export default {}")

      backdated = DateTime.truncate(DateTime.add(DateTime.utc_now(), -60, :second), :second)

      Repo.update_all(
        from(a in Servant.Apps.UserApp, where: a.id == ^app.id),
        set: [updated_at: backdated]
      )

      dir = Path.join(System.tmp_dir!(), "servant-app-#{Ecto.UUID.generate()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "index.js"), "export default {}")

      manifest = %{"id" => "gen-todo", "name" => "Gen App", "entry" => "index.js"}
      File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, updated} = Apps.update_from_dir(app, dir)
      assert DateTime.compare(updated.updated_at, backdated) == :gt
    end
  end
end
