defmodule ServantWeb.Schemas.Entry do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Entry",
    description:
      "Universal user-scoped data container. Notes are entries too but are written through /api/notes.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      kind: %Schema{type: :string, example: "tracker_log"},
      source: %Schema{type: :string, example: "api"},
      external_id: %Schema{type: :string, nullable: true},
      title: %Schema{type: :string, nullable: true},
      occurred_at: %Schema{type: :string, format: :"date-time", nullable: true},
      data: %Schema{type: :object, additionalProperties: true},
      metadata: %Schema{type: :object, additionalProperties: true, nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :kind]
  })
end
