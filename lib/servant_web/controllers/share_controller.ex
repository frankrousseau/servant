defmodule ServantWeb.ShareController do
  @moduledoc """
  The public side of photo-feed links. There is no authentication: the token
  in the URL is the whole credential. Returns the feed as JSON for the
  `/share/<token>` page. `ServantWeb.ShareFileController` serves the files of
  the photos.

  An unknown or revoked token is a plain 404, with no distinction between the
  two. As a result, a leaked link tells nothing after it is revoked.
  """

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.PhotoShares
  alias ServantWeb.Schemas

  tags(["photo shares"])

  operation(:show,
    summary: "Public photo feed behind a share link",
    description:
      "No authentication: the token is the credential. Per photo, only neutral fields (title, date, type) and file URLs under `/share/<token>/files/`; no EXIF location, no people.",
    parameters: [token: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Feed", "application/json",
         %Schema{
           type: :object,
           properties: %{
             name: %Schema{type: :string, nullable: true},
             tags: %Schema{type: :array, items: %Schema{type: :string}},
             match: %Schema{type: :string, enum: ["any", "all"]},
             photos: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 properties: %{
                   id: %Schema{type: :string, format: :uuid},
                   title: %Schema{type: :string, nullable: true},
                   occurred_at: %Schema{type: :string, format: :"date-time", nullable: true},
                   mime_type: %Schema{type: :string, nullable: true},
                   video: %Schema{type: :boolean},
                   thumb: %Schema{type: :string, nullable: true},
                   src: %Schema{type: :string, nullable: true},
                   full: %Schema{type: :string, nullable: true}
                 }
               }
             }
           }
         }},
      not_found: {"Unknown or revoked link", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"token" => token}) do
    case PhotoShares.get_by_token(token) do
      nil ->
        not_found(conn)

      share ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(PhotoShares.feed_json(share, PhotoShares.photos(share)))
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end
end
