defmodule ServantWeb.ErrorJSON do
  @moduledoc """
  Your endpoint invokes this module when errors occur on JSON requests.

  See config/config.exs.
  """

  # To customize a particular status code,
  # you can add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
