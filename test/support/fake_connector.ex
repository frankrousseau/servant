defmodule Servant.FakeConnector do
  @moduledoc """
  Minimal connector used in worker tests. Emits one entry per sync and advances
  a cursor, so we can assert the worker persists `persisted_config/1`.
  """

  use Servant.Connectors.Connector

  @impl true
  def id, do: "fake"

  @impl true
  def name, do: "Fake"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "note"

  @impl true
  def init(_credentials, config) do
    if Map.get(config, "fail_init") do
      {:error, :init_failed}
    else
      {:ok,
       %{
         cursor: Map.get(config, "cursor", "start"),
         fail_sync: Map.get(config, "fail_sync", false)
       }}
    end
  end

  @impl true
  def sync(%{fail_sync: true} = state) do
    {:error, :sync_failed, state}
  end

  def sync(state) do
    entry = %{"kind" => "note", "source" => "fake", "title" => "synced"}
    {:ok, [entry], %{state | cursor: "advanced"}}
  end

  @impl true
  def persisted_config(state), do: %{"cursor" => state.cursor}
end
