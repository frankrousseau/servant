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
        # `to_existing_atom` guards against an unexpected placeholder raising
        # (which would turn a 422 into a 500); fall back to the literal key.
        atom = safe_existing_atom(key)
        value = if atom, do: Keyword.get(opts, atom, key), else: key
        to_string(value)
      end)
    end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
