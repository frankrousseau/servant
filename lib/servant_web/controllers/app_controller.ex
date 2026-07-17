defmodule ServantWeb.AppController do
  @moduledoc "Lists built-in and installed apps; installs apps from git."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Servant.Accounts
  alias Servant.Agents
  alias Servant.Apps
  alias Servant.Apps.Generator
  alias ServantWeb.Schemas

  tags(["apps"])

  plug :require_agents when action in [:generate, :modify, :restore, :runs, :run]

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

  operation(:update,
    summary: "Update an installed app",
    description:
      "Session-only. Re-clones the app's stored repository, re-validates its " <>
        "manifest (the id must not change) and replaces the app's files.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Updated app", "application/json", %Schema{type: :object}},
      unprocessable_entity: {"Invalid app", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => app_id}) do
    case Apps.update_from_git(conn.assigns.current_user.id, app_id) do
      {:ok, app} ->
        json(conn, %{data: installed_json(app)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "App not found"})

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

  operation(:generate,
    summary: "Generate an app from a description (builder agent)",
    description:
      "Session-only; requires agents enabled in Settings. Starts an async " <>
        "run on the configured model server and returns it for polling. Only " <>
        "the name and description are sent to the model, never personal data.",
    request_body:
      {"Generation request", "application/json",
       %Schema{
         type: :object,
         properties: %{name: %Schema{type: :string}, description: %Schema{type: :string}},
         required: [:name, :description]
       }},
    responses: [
      accepted: {"Run", "application/json", %Schema{type: :object}},
      unprocessable_entity: {"Invalid request", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def generate(conn, params) do
    user = conn.assigns.current_user

    case Generator.start_generate(user, params["name"], params["description"]) do
      {:ok, run} ->
        conn |> put_status(:accepted) |> json(%{data: run_json(run)})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  operation(:modify,
    summary: "Modify a generated app (builder agent)",
    description:
      "Session-only; requires agents enabled. Sends the app's current module " <>
        "and the instruction to the model; the previous version is kept.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Modification request", "application/json",
       %Schema{
         type: :object,
         properties: %{instruction: %Schema{type: :string}},
         required: [:instruction]
       }},
    responses: [
      accepted: {"Run", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid request", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def modify(conn, %{"id" => app_id} = params) do
    case Generator.start_modify(conn.assigns.current_user, app_id, params["instruction"]) do
      {:ok, run} ->
        conn |> put_status(:accepted) |> json(%{data: run_json(run)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "App not found"})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  operation(:restore,
    summary: "Restore a generated app's previous version",
    description: "Session-only; requires agents enabled. Swaps the module with index.prev.js.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Restored app", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"No previous version", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def restore(conn, %{"id" => app_id}) do
    case Apps.restore_previous(conn.assigns.current_user.id, app_id) do
      {:ok, app} ->
        json(conn, %{data: installed_json(app)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "App not found"})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  operation(:runs,
    summary: "List agent runs (model, tokens, duration)",
    description: "Session-only; requires agents enabled. Newest first, 50 max.",
    responses: [
      ok: {"Runs", "application/json", %Schema{type: :object}},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def runs(conn, _params) do
    runs = Agents.list_runs(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(runs, &run_json/1)})
  end

  operation(:run,
    summary: "Get one agent run (for polling)",
    description: "Session-only; requires agents enabled.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Run", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def run(conn, %{"id" => id}) do
    case Agents.get_run(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Run not found"})
      run -> json(conn, %{data: run_json(run)})
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
      repo_url: app.repo_url,
      updated_at: app.updated_at,
      generated: is_nil(app.repo_url),
      has_previous: Apps.previous_version?(app)
    }
  end

  defp require_agents(conn, _opts) do
    if Accounts.ai_enabled?(conn.assigns.current_user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "AI agents are disabled in Settings"})
      |> halt()
    end
  end

  defp run_json(run) do
    %{
      id: run.id,
      type: run.type,
      action: run.action,
      app_id: run.app_id,
      status: run.status,
      model: run.model,
      prompt: run.prompt,
      input_tokens: run.input_tokens,
      output_tokens: run.output_tokens,
      duration_ms: run.duration_ms,
      error: run.error,
      inserted_at: run.inserted_at
    }
  end
end
