defmodule ServantWeb.AppController do
  @moduledoc "Lists built-in and installed apps; installs apps from git."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Servant.Apps
  alias ServantWeb.Schemas

  tags(["apps"])

  operation(:index,
    summary: "List apps (built-in and installed)",
    description: "No scope required beyond authentication (session or any API token).",
    responses: [
      ok:
        {"Apps", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 properties: %{
                   id: %Schema{type: :string},
                   name: %Schema{type: :string},
                   description: %Schema{type: :string},
                   icon: %Schema{type: :string},
                   route: %Schema{type: :string},
                   built_in: %Schema{type: :boolean}
                 }
               }
             }
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    apps = [
      %{
        id: "contacts",
        name: "Contacts",
        description: "Browse and search your imported contacts",
        icon: "user-round",
        route: "/apps/contacts",
        built_in: true
      },
      %{
        id: "calendar",
        name: "Calendar",
        description: "View your events in a monthly calendar",
        icon: "calendar-days",
        route: "/apps/calendar",
        built_in: true
      },
      %{
        id: "files",
        name: "Files",
        description: "Create folders and upload files",
        icon: "folder-open",
        route: "/apps/files",
        built_in: true
      },
      %{
        id: "photos",
        name: "Photos",
        description: "Upload, browse and organize your photos",
        icon: "image",
        route: "/apps/photos",
        built_in: true
      },
      %{
        id: "notes",
        name: "Notes",
        description: "Write linked markdown notes with wikilinks and backlinks",
        icon: "notebook-pen",
        route: "/apps/notes",
        built_in: true
      }
    ]

    installed =
      conn.assigns.current_user.id
      |> Apps.list_apps()
      |> Enum.map(&installed_json/1)

    json(conn, %{data: apps ++ installed})
  end

  operation(:create,
    summary: "Install an app from a git repository",
    description:
      "Session-only. Clones the https repo, validates its servant-app.json " <>
        "manifest, and installs the app for the current user. The app's entry " <>
        "module runs in the SPA with the user's full session privileges.",
    request_body:
      {"Install attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{repo_url: %Schema{type: :string, description: "https git URL"}},
         required: [:repo_url]
       }},
    responses: [
      created: {"Installed app", "application/json", %Schema{type: :object}},
      unprocessable_entity: {"Invalid app", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case Apps.install_from_git(user_id, params["repo_url"]) do
      {:ok, app} ->
        conn
        |> put_status(:created)
        |> json(%{data: installed_json(app)})

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})
    end
  end

  operation(:delete,
    summary: "Uninstall an installed app",
    description: "Session-only. Removes the app's files and sidebar entry.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: {"Uninstalled", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => app_id}) do
    case Apps.uninstall(conn.assigns.current_user.id, app_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "App not found"})
    end
  end

  defp installed_json(app) do
    %{
      id: app.app_id,
      name: app.name,
      description: app.description,
      icon: app.icon,
      route: "/apps/#{app.app_id}",
      built_in: false,
      entry_url: Apps.entry_url(app),
      repo_url: app.repo_url
    }
  end
end
