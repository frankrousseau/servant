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
                   login register app apps)

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
      tmp = Storage.tmp_workspace(user_id)
      dest = Path.join(tmp, "repo")

      try do
        case git_clone(repo_url, dest) do
          :ok -> install_from_dir(user_id, dest, repo_url)
          {:error, msg} -> {:error, msg}
        end
      after
        Storage.cleanup_tmp(tmp)
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
         :ok <- validate_manifest(user_id, manifest),
         :ok <- validate_entry(dir, manifest["entry"]) do
      File.rm_rf(Path.join(dir, ".git"))
      app_dir = install_dir(user_id, manifest["id"])
      File.rm_rf(app_dir)
      File.mkdir_p!(Path.dirname(app_dir))
      File.cp_r!(dir, app_dir)

      attrs = %{
        app_id: manifest["id"],
        name: manifest["name"],
        description: truncate(manifest["description"], 255),
        icon: truncate(manifest["icon"], 60),
        entry: manifest["entry"],
        repo_url: repo_url
      }

      case %UserApp{user_id: user_id} |> UserApp.changeset(attrs) |> Repo.insert() do
        {:ok, app} ->
          {:ok, app}

        {:error, _changeset} ->
          File.rm_rf(app_dir)
          {:error, "an app with id \"#{manifest["id"]}\" is already installed"}
      end
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

  defp validate_manifest(user_id, manifest) do
    id = manifest["id"]
    name = manifest["name"]

    cond do
      not (is_binary(id) and id =~ ~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/) ->
        {:error, "manifest id must be lowercase alphanumeric (dashes allowed)"}

      id in @reserved_ids ->
        {:error, "app id \"#{id}\" is reserved"}

      not (is_binary(name) and name != "" and String.length(name) <= 60) ->
        {:error, "manifest name is required (60 chars max)"}

      get_app(user_id, id) != nil ->
        {:error, "an app with id \"#{id}\" is already installed"}

      true ->
        :ok
    end
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
