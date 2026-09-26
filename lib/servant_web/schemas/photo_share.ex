defmodule ServantWeb.Schemas.PhotoShare do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PhotoShare",
    description:
      "A public link over the photos carrying one or more tags or people. The feed is computed when the link is opened.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string, nullable: true},
      tags: %Schema{type: :array, items: %Schema{type: :string}, example: ["holidays"]},
      people: %Schema{
        type: :array,
        description: "contacts tagged on the photos, name kept as a label",
        items: %Schema{
          type: :object,
          properties: %{id: %Schema{type: :string}, name: %Schema{type: :string}}
        }
      },
      match: %Schema{
        type: :string,
        enum: ["any", "all"],
        description:
          "any: photos carrying at least one of the tags or people; all: photos carrying every one"
      },
      token: %Schema{type: :string},
      path: %Schema{
        type: :string,
        description: "Path of the public page on this instance",
        example: "/share/2qJ7…"
      },
      inserted_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :tags, :match, :token, :path]
  })
end
