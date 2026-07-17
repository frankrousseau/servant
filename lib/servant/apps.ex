defmodule Servant.Apps do
  @moduledoc """
  Installable user apps: cloned from a git repository, described by a
  `servant-app.json` manifest at the repo root, and served to the SPA from
  per-user file storage.

  The manifest requires `id`, `name`, and `entry` (a repo-relative path to a
  pre-built, self-contained ES module default-exporting an AppModule); `icon`
  (lucide icon name) and `description` are optional. No build step runs on
  the server, so the repository must commit its built entry file.
  """

  import Ecto.Query

  alias Servant.Apps.UserApp
  alias Servant.Repo
  alias Servant.Storage

  @manifest "servant-app.json"

  # Builtin app ids plus SPA top-level routes an installed app must not shadow
  @reserved_ids ~w(calendar checklists contacts files finance notes photos
                   trackers dashboard data connectors settings profile audit
                   login register agents app apps)

  def list_apps(user_id) do
    UserApp
    |> where(user_id: ^user_id)
    |> order_by(:name)
    |> Repo.all()
  end

  def get_app(user_id, app_id) do
    Repo.get_by(UserApp, user_id: user_id, app_id: app_id)
  end

  @doc """
  Clones `repo_url` (https only) and installs the app it contains for
  `user_id`. Returns `{:ok, %UserApp{}}` or `{:error, message}`.
  """
  def install_from_git(user_id, repo_url) do
    with :ok <- validate_repo_url(repo_url) do
      with_cloned_repo(user_id, repo_url, fn dir ->
        install_from_dir(user_id, dir, repo_url)
      end)
    end
  end

  @doc """
  Re-clones the stored repo_url of an installed app, re-validates its
  manifest (the id must not change) and replaces the app's files and
  metadata. Returns `{:ok, %UserApp{}}`, `{:error, :not_found}` or
  `{:error, message}`.
  """
  def update_from_git(user_id, app_id) do
    case get_app(user_id, app_id) do
      nil ->
        {:error, :not_found}

      app ->
        if generated?(app) do
          {:error, "generated apps have no git repository to update from"}
        else
          with_cloned_repo(user_id, app.repo_url, &update_from_dir(app, &1))
        end
    end
  end

  @doc """
  Installs the app contained in `dir` (a checked-out repository). Exposed
  separately from the git clone so tests can exercise the whole flow without
  network access.
  """
  def install_from_dir(user_id, dir, repo_url) do
    with {:ok, manifest} <- read_manifest(dir),
         :ok <- validate_manifest_fields(manifest),
         :ok <- ensure_not_installed(user_id, manifest["id"]),
         :ok <- validate_entry(dir, manifest["entry"]) do
      copy_app_files(user_id, manifest["id"], dir)
      attrs = Map.put(manifest_attrs(manifest), :repo_url, repo_url)

      case %UserApp{user_id: user_id} |> UserApp.changeset(attrs) |> Repo.insert() do
        {:ok, app} ->
          {:ok, app}

        {:error, _changeset} ->
          File.rm_rf(install_dir(user_id, manifest["id"]))
          {:error, "an app with id \"#{manifest["id"]}\" is already installed"}
      end
    end
  end

  @doc """
  Updates an installed app from a checked-out repository. Exposed separately
  from the git clone so tests can exercise the flow without network access.
  """
  def update_from_dir(%UserApp{} = app, dir) do
    with {:ok, manifest} <- read_manifest(dir),
         :ok <- validate_manifest_fields(manifest),
         :ok <- ensure_same_id(app, manifest["id"]),
         :ok <- validate_entry(dir, manifest["entry"]) do
      copy_app_files(app.user_id, app.app_id, dir)

      # force: true bumps updated_at even when the manifest reproduces the
      # same fields (?v= is the SPA's only ES-module cache-buster)
      app
      |> UserApp.changeset(manifest_attrs(manifest))
      |> Repo.update(force: true)
    end
  end

  def uninstall(user_id, app_id) do
    case get_app(user_id, app_id) do
      nil ->
        {:error, :not_found}

      app ->
        Repo.delete(app)
        File.rm_rf(install_dir(user_id, app_id))
        :ok
    end
  end

  @doc "Path the SPA imports the app's entry module from (cookie-authenticated)."
  def entry_url(%UserApp{} = app) do
    "/files/#{app.user_id}/installed_apps/#{app.app_id}/#{app.entry}"
  end

  def install_dir(user_id, app_id) do
    Storage.join_files([user_id, "installed_apps", app_id])
  end

  @doc "True when the app was written by the builder agent (no git repo)."
  def generated?(%UserApp{repo_url: repo_url}), do: is_nil(repo_url)

  @doc "True when the app has a restorable previous version on disk."
  def previous_version?(%UserApp{} = app) do
    generated?(app) and
      File.regular?(Path.join(install_dir(app.user_id, app.app_id), "index.prev.js"))
  end

  @doc """
  Swaps a generated app's entry module with its saved previous version
  (`index.prev.js`) and bumps updated_at so the SPA reloads the module.
  """
  def restore_previous(user_id, app_id) do
    app = get_app(user_id, app_id)
    dir = install_dir(user_id, app_id)
    prev = Path.join(dir, "index.prev.js")

    cond do
      is_nil(app) ->
        {:error, :not_found}

      not generated?(app) ->
        {:error, "only generated apps have a restorable version"}

      not File.regular?(prev) ->
        {:error, "no previous version to restore"}

      true ->
        current = Path.join(dir, app.entry)
        swap = Path.join(dir, "index.swap.js")
        File.rename!(current, swap)
        File.rename!(prev, current)
        File.rename!(swap, prev)
        # force: true bumps updated_at even without changes (?v= cache busting)
        app |> UserApp.changeset(%{}) |> Repo.update(force: true)
    end
  end

  # --- Clone / file helpers ---

  defp with_cloned_repo(user_id, repo_url, fun) do
    tmp = Storage.tmp_workspace(user_id)
    dest = Path.join(tmp, "repo")

    try do
      case git_clone(repo_url, dest) do
        :ok -> fun.(dest)
        {:error, msg} -> {:error, msg}
      end
    after
      Storage.cleanup_tmp(tmp)
    end
  end

  defp copy_app_files(user_id, app_id, dir) do
    File.rm_rf(Path.join(dir, ".git"))
    app_dir = install_dir(user_id, app_id)
    File.rm_rf(app_dir)
    File.mkdir_p!(Path.dirname(app_dir))
    File.cp_r!(dir, app_dir)
  end

  defp manifest_attrs(manifest) do
    %{
      app_id: manifest["id"],
      name: manifest["name"],
      description: truncate(manifest["description"], 255),
      icon: truncate(manifest["icon"], 60),
      entry: manifest["entry"]
    }
  end

  # --- Validation ---

  defp validate_repo_url(url) when is_binary(url) do
    if url =~ ~r{\Ahttps://\S+\z} do
      :ok
    else
      {:error, "repo_url must be an https:// git URL"}
    end
  end

  defp validate_repo_url(_), do: {:error, "repo_url must be an https:// git URL"}

  defp git_clone(url, dest) do
    # GIT_TERMINAL_PROMPT=0 fails fast instead of hanging on a credential prompt
    case System.cmd(
           "git",
           ["clone", "--depth", "1", "--quiet", "--", url, dest],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git clone failed: #{String.slice(output, 0, 500)}"}
    end
  rescue
    ErlangError -> {:error, "git is not installed on the server"}
  end

  defp read_manifest(dir) do
    with {:ok, raw} <- File.read(Path.join(dir, @manifest)),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw) do
      {:ok, manifest}
    else
      _ -> {:error, "the repository must contain a valid #{@manifest} at its root"}
    end
  end

  defp validate_manifest_fields(manifest) do
    id = manifest["id"]
    name = manifest["name"]

    cond do
      not (is_binary(id) and id =~ ~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/) ->
        {:error, "manifest id must be lowercase alphanumeric (dashes allowed)"}

      id in @reserved_ids ->
        {:error, "app id \"#{id}\" is reserved"}

      not (is_binary(name) and name != "" and String.length(name) <= 60) ->
        {:error, "manifest name is required (60 chars max)"}

      true ->
        :ok
    end
  end

  defp ensure_not_installed(user_id, app_id) do
    if get_app(user_id, app_id) do
      {:error, "an app with id \"#{app_id}\" is already installed"}
    else
      :ok
    end
  end

  defp ensure_same_id(%UserApp{app_id: app_id}, app_id), do: :ok

  defp ensure_same_id(%UserApp{app_id: expected}, actual) do
    {:error, "manifest id changed (expected \"#{expected}\", got \"#{actual}\")"}
  end

  defp validate_entry(dir, entry) do
    with true <- is_binary(entry),
         true <- Path.extname(entry) in [".js", ".mjs"],
         {:ok, safe} <- Path.safe_relative(entry),
         true <- File.regular?(Path.join(dir, safe)) do
      :ok
    else
      _ -> {:error, "manifest entry must point to a .js module committed in the repository"}
    end
  end

  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp truncate(_, _), do: nil
end
