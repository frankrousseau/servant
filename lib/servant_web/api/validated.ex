defmodule ServantWeb.Api.Validated do
  @moduledoc """
  Validates the requests of a controller against the OpenAPI operation declared
  for the action. A body or a query param that contradicts the spec gets a 422
  before the action runs. Without this module, the spec is documentation only.

  Add `use ServantWeb.Api.Validated` after `use OpenApiSpex.ControllerSpecs`.

  The cast runs with `replace_params: false`. `conn.params` keeps the raw map
  with string keys that each action here reads. As a result, validation is the
  only effect.
  """

  defmacro __using__(_opts) do
    quote do
      plug OpenApiSpex.Plug.CastAndValidate,
        replace_params: false,
        render_error: ServantWeb.Plugs.OpenApiError
    end
  end
end
