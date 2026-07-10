defmodule ServantWeb.Schemas.ApiToken do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ApiToken",
    description: "A scoped, individually revocable API token. Only the SHA-256 hash is stored.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string},
      prefix: %Schema{type: :string},
      scopes: %Schema{
        type: :array,
        items: %Schema{type: :string},
        example: ["app:trackers:write"]
      },
      expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
      last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      token: %Schema{
        type: :string,
        description: "full plaintext, present only in the create response"
      }
    },
    required: [:id, :name, :prefix, :scopes]
  })
end
