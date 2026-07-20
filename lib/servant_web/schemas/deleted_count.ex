defmodule ServantWeb.Schemas.DeletedCount do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DeletedCount",
    description: "Result of a bulk delete.",
    type: :object,
    properties: %{
      deleted: %Schema{type: :integer, description: "number of entries deleted"}
    },
    required: [:deleted]
  })
end
