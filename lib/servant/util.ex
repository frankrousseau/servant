defmodule Servant.Util do
  @moduledoc """
  Small shared helpers used across contexts (kept here to avoid copies drifting).
  """

  @doc "Strips a leading UTF-8 BOM from a binary, if present."
  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  def strip_bom(content), do: content

  @doc """
  Parses an integer from a string, returning `default` on failure. Passes
  integers through and falls back to `default` for anything else (e.g. `nil`).
  """
  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  def parse_int(val, _default) when is_integer(val), do: val
  def parse_int(_val, default), do: default
end
