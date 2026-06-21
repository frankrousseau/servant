defmodule Servant.Storage do
  @moduledoc """
  File storage layout on disk:

      $FILES_DIR/{user_id}/apps/{app_id}/{uuid}{ext}
      $FILES_DIR/{user_id}/account/avatar{ext}
      $FILES_DIR/{user_id}/connectors/{type}/{config_id}/{stamp}-{name}

      $TMP_DIR/{user_id}/{workspace_id}/…   (processing scratch space)
  """

  @allowed_apps ~w(photos files contacts)

  def files_root do
    env_dir("FILES_DIR") || default_priv("files")
  end

  def tmp_root do
    env_dir("TMP_DIR") || default_priv("tmp")
  end

  def public_url(relative_path) when is_binary(relative_path) do
    "/files/" <> String.trim_leading(relative_path, "/")
  end

  def join_files(parts), do: Path.join([files_root() | parts])

  def join_tmp(parts), do: Path.join([tmp_root() | parts])

  @doc """
  Stores an app upload. `app_id` must be one of: #{Enum.join(@allowed_apps, ", ")}.
  Returns `{:ok, relative_path, absolute_path}`.
  """
  def store_app_file(user_id, app_id, src_path, opts \\ []) do
    with :ok <- validate_app(app_id) do
      ext = extension(opts)
      uuid = Ecto.UUID.generate()
      relative = Path.join([user_id, "apps", app_id, "#{uuid}#{ext}"])
      absolute = join_files([relative])
      write_file!(absolute, src_path)
      {:ok, relative, absolute}
    end
  end

  def store_account_avatar(user_id, src_path, ext) do
    relative = Path.join([user_id, "account", "avatar#{ext}"])
    absolute = join_files([relative])
    write_file!(absolute, src_path)
    {:ok, relative, absolute}
  end

  @doc """
  Archives a connector import file after successful processing.
  """
  def store_connector_file(user_id, connector_type, config_id, src_path, original_name) do
    stamp = DateTime.utc_now() |> DateTime.to_unix()
    safe_name = sanitize_filename(original_name)

    relative =
      Path.join([user_id, "connectors", connector_type, config_id, "#{stamp}-#{safe_name}"])

    absolute = join_files([relative])
    write_file!(absolute, src_path)
    {:ok, relative, absolute}
  end

  @doc """
  Creates a temporary workspace directory for processing. Caller must call `cleanup_tmp/1`.
  """
  def tmp_workspace(user_id) do
    workspace_id = Ecto.UUID.generate()
    absolute = join_tmp([user_id, workspace_id])
    File.mkdir_p!(absolute)
    absolute
  end

  def cleanup_tmp(path) when is_binary(path) do
    File.rm_rf(path)
    :ok
  end

  def resolve_public_path(relative) when is_binary(relative) do
    relative = URI.decode(relative) |> String.trim_leading("/")

    if path_safe?(relative) do
      absolute = join_files([relative])

      cond do
        File.regular?(absolute) -> {:ok, absolute}
        true -> legacy_resolve(relative)
      end
    else
      :error
    end
  end

  defp legacy_resolve("app_files/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [user_id, filename] ->
        candidates =
          for app <- @allowed_apps do
            join_files([user_id, "apps", app, filename])
          end

        Enum.find_value(candidates, fn path ->
          if File.regular?(path), do: {:ok, path}
        end) || legacy_uploads_path("app_files/" <> rest)

      _ ->
        legacy_uploads_path("app_files/" <> rest)
    end
  end

  defp legacy_resolve("avatars/" <> filename) do
    case String.split(filename, ".", parts: 2) do
      [user_id, ext] ->
        path = join_files([user_id, "account", "avatar.#{ext}"])
        if File.regular?(path), do: {:ok, path}, else: legacy_uploads_path("avatars/" <> filename)

      _ ->
        legacy_uploads_path("avatars/" <> filename)
    end
  end

  defp legacy_resolve(relative), do: legacy_uploads_path(relative)

  defp legacy_uploads_path(relative) do
    legacy_root = env_dir("UPLOADS_DIR") || default_priv("uploads")
    path = Path.join(legacy_root, relative)
    if File.regular?(path), do: {:ok, path}, else: :error
  end

  defp validate_app(app) when app in @allowed_apps, do: :ok
  defp validate_app(app), do: {:error, "Unknown app: #{app}"}

  defp extension(opts) do
    ext = Keyword.get(opts, :ext, "")
    if ext == "" or String.starts_with?(ext, "."), do: ext, else: ".#{ext}"
  end

  defp write_file!(absolute, src_path) do
    File.mkdir_p!(Path.dirname(absolute))
    File.cp!(src_path, absolute)
  end

  defp sanitize_filename(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]+/u, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "import"
      safe -> safe
    end
  end

  defp path_safe?(relative), do: not String.contains?(relative, "..")

  defp env_dir(key) do
    case System.get_env(key) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end

  defp default_priv(name), do: Path.join(:code.priv_dir(:servant) |> to_string(), name)
end
