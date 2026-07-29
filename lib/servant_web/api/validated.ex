defmodule ServantWeb.Api.Validated do
  @moduledoc """
  Validates a controller's requests against the OpenAPI operation declared for
  the action: a body or query param that contradicts the spec is rejected with
  422 before the action runs, instead of the spec being documentation only.

  `use ServantWeb.Api.Validated` after `use OpenApiSpex.ControllerSpecs`.

  Casting runs with `replace_params: false`: `conn.params` keeps the raw
  string-keyed map every action here reads, so validation is the only effect.
  """

  defmacro __using__(_opts) do
    quote do
      plug OpenApiSpex.Plug.CastAndValidate,
        replace_params: false,
        render_error: ServantWeb.Plugs.OpenApiError
    end
  end
end
