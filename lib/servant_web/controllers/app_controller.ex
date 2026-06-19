defmodule ServantWeb.AppController do
  use ServantWeb, :controller

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
      }
    ]

    json(conn, %{data: apps})
  end
end
