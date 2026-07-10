defmodule ServantWeb.Schemas.Error do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Error",
    description: "Standard error envelope returned on failed requests.",
    type: :object,
    properties: %{
      error: %Schema{type: :string},
      required: %Schema{type: :string, description: "missing scope, on 403"},
      errors: %Schema{
        type: :object,
        additionalProperties: true,
        description: "changeset errors, keyed by field"
      }
    },
    required: [:error]
  })
end
