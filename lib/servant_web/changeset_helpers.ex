defmodule ServantWeb.ChangesetHelpers do
  @moduledoc """
  Shared helpers for rendering Ecto changeset errors in JSON responses.
  """

  @doc """
  Traverse a changeset's errors into a map of `field => [messages]`,
  interpolating the `%{count}`-style placeholders Ecto leaves in messages.
  """
  def format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
