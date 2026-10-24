defmodule ServantWeb.VersionController do
  @moduledoc "Returns the backend build that this instance runs."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.BuildInfo

  tags(["system"])

  operation(:show,
    summary: "Backend build info",
    description: "Git commit and date the running backend was compiled from.",
    responses: [
      ok:
        {"Build info", "application/json",
         %Schema{
           type: :object,
           properties: %{
             commit: %Schema{type: :string},
             built_at: %Schema{type: :string, description: "compile date, YYYY-MM-DD"}
           }
         }}
    ]
  )

  def show(conn, _params) do
    json(conn, %{commit: BuildInfo.commit(), built_at: BuildInfo.date()})
  end
end
