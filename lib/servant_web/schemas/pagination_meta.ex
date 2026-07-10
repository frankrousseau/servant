defmodule ServantWeb.Schemas.PaginationMeta do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PaginationMeta",
    description: "Pagination metadata accompanying a list response.",
    type: :object,
    properties: %{
      page: %Schema{type: :integer},
      per_page: %Schema{type: :integer},
      total: %Schema{type: :integer},
      total_pages: %Schema{type: :integer}
    },
    required: [:page, :per_page, :total, :total_pages]
  })
end
