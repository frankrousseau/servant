defmodule ServantWeb.ChangesetHelpers do
  @moduledoc """
  Shared helpers that render Ecto changeset errors in JSON responses.
  """

  @doc """
  Traverses the errors of a changeset into a map of `field => [messages]`.
  Interpolates the placeholders in the `%{count}` style that Ecto leaves in
  the messages.
  """
  def format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        # The `to_existing_atom` guard prevents a raise on an unexpected placeholder
        # (a raise would change a 422 into a 500). If the atom does not exist, use
        # the literal key.
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
