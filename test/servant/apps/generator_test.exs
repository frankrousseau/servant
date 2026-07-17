defmodule Servant.Apps.GeneratorTest do
  use Servant.DataCase

  alias Servant.Accounts
  alias Servant.Apps
  alias Servant.Apps.Generator

  @valid_reply """
  Here is your app:

  ```js
  export default {
    mount(el, ctx) { el.textContent = 'hello' },
    unmount(el) {}
  }
  ```
  """

  # Mirrors the on_exit cleanup in test/servant/apps_test.exs's setup block,
  # attached per-user here (not in a top-level setup) because each test
  # builds its own agents-enabled user through this helper rather than a
  # shared context user; install_dir still ends up disposable.
  defp user_with_agents do
    user = user_fixture()
    on_exit(fn -> File.rm_rf(Servant.Storage.join_files([user.id])) end)

    {:ok, user} =
      Accounts.update_ai_config(user, %{
        "enabled" => true,
        "model" => "test-model",
        "base_url" => "http://localhost:9999/v1"
      })

    user
  end

  defp ai_reply(content) do
    fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => content}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}
      })
    end
  end

  describe "generate_now/4" do
    test "installs the app and completes the run" do
      user = user_with_agents()

      assert {:ok, app, run} =
               Generator.generate_now(user, "My Todo", "track todos",
                 plug: ai_reply(@valid_reply)
               )

      assert app.app_id == "my-todo"
      assert app.repo_url == nil
      assert app.entry == "index.js"

      code = File.read!(Path.join(Apps.install_dir(user.id, "my-todo"), "index.js"))
      assert code =~ "export default"

      assert run.status == "ok"
      assert run.action == "create"
      assert run.model == "test-model"
      assert run.input_tokens == 10
      assert run.output_tokens == 20
      assert is_integer(run.duration_ms)
    end

    test "refuses when agents are disabled" do
      assert {:error, message} = Generator.generate_now(user_fixture(), "X", "y")
      assert message =~ "disabled"
    end

    test "refuses a blank name or description" do
      user = user_with_agents()
      assert {:error, _} = Generator.generate_now(user, "", "desc")
      assert {:error, _} = Generator.generate_now(user, "Name", " ")
      assert {:error, _} = Generator.generate_now(user, "!!!", "desc")
    end

    test "retries once on an invalid reply, then fails the run" do
      user = user_with_agents()
      counter = start_supervised!({Agent, fn -> 0 end})

      plug = fn conn ->
        Agent.update(counter, &(&1 + 1))
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "no code here"}}]})
      end

      assert {:error, message, run} = Generator.generate_now(user, "Todo", "todo app", plug: plug)
      assert message =~ "did not return a valid module"
      assert run.status == "error"
      assert Agent.get(counter, & &1) == 2
    end

    test "a reserved app name fails the run with the install error" do
      user = user_with_agents()

      assert {:error, message, run} =
               Generator.generate_now(user, "Settings", "x", plug: ai_reply(@valid_reply))

      assert message =~ "reserved"
      assert run.status == "error"
    end

    test "an unexpected raise still fails the run instead of leaving it stuck running" do
      user = user_with_agents()

      assert_raise RuntimeError, "boom", fn ->
        Generator.generate_now(user, "Boom App", "x", plug: fn _conn -> raise "boom" end)
      end

      assert [run] = Servant.Agents.list_runs(user.id)
      assert run.status == "error"
      assert run.error =~ "boom"
    end
  end

  describe "modify_now/4" do
    test "rewrites the module and keeps the previous version" do
      user = user_with_agents()

      {:ok, app, _run} =
        Generator.generate_now(user, "My Todo", "track todos", plug: ai_reply(@valid_reply))

      original = File.read!(Path.join(Apps.install_dir(user.id, app.app_id), "index.js"))

      new_reply = """
      ```js
      export default { mount(el) { el.textContent = 'v2' }, unmount(el) {} }
      ```
      """

      assert {:ok, app, run} =
               Generator.modify_now(user, "my-todo", "say v2", plug: ai_reply(new_reply))

      dir = Apps.install_dir(user.id, "my-todo")
      assert File.read!(Path.join(dir, "index.js")) =~ "v2"
      assert File.read!(Path.join(dir, "index.prev.js")) == original
      assert Apps.previous_version?(app)
      assert run.action == "modify"
    end

    test "refuses unknown and non-generated apps" do
      user = user_with_agents()
      assert Generator.modify_now(user, "nope", "x") == {:error, :not_found}

      dir = Path.join(System.tmp_dir!(), "servant-app-#{Ecto.UUID.generate()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "index.js"), "export default { mount() {} }")

      manifest = %{"id" => "git-app", "name" => "Git App", "entry" => "index.js"}
      File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, app} = Apps.install_from_dir(user.id, dir, "https://example.com/git-app.git")

      assert {:error, message} = Generator.modify_now(user, app.app_id, "x")
      assert message =~ "generated"
    end
  end

  describe "extract_module/1" do
    test "takes the last js block" do
      content = "```js\nconst a = 1\n```\ntext\n```js\nexport default {}\n```"
      assert {:ok, code} = Generator.extract_module(content)
      assert code =~ "export default"
      refute code =~ "const a"
    end

    test "rejects a reply without a block or without export default" do
      assert {:error, _} = Generator.extract_module("no code")
      assert {:error, _} = Generator.extract_module("```js\nconst x = 1\n```")
    end
  end

  test "slugify/1" do
    assert Generator.slugify("My Todo App!") == "my-todo-app"
    assert Generator.slugify("  éé  ") == ""
    assert Generator.slugify(nil) == ""
  end
end
