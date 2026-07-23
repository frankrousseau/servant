defmodule Servant.BuildInfo do
  @moduledoc """
  Git commit and date captured at compile time, so a running instance can
  say which version it is (Settings shows it next to the UI build).
  """

  # Recompile when a commit lands, not only when this file changes.
  if File.exists?(".git/logs/HEAD") do
    @external_resource Path.expand(".git/logs/HEAD")
  end

  @commit (try do
             case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
               {out, 0} -> String.trim(out)
               _ -> "unknown"
             end
           rescue
             _ -> "unknown"
           end)

  @date Date.to_iso8601(Date.utc_today())

  @spec commit() :: String.t()
  def commit, do: @commit

  @spec date() :: String.t()
  def date, do: @date
end
