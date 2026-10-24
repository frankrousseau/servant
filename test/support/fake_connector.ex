defmodule Servant.FakeConnector do
  @moduledoc """
  This module is a minimal connector for the worker tests. It emits one entry
  for each sync and advances a cursor. As a result, the tests can make sure
  that the worker persists `persisted_config/1`.
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
         fail_sync: Map.get(config, "fail_sync", false),
         raise_sync: Map.get(config, "raise_sync", false),
         user_id: Map.get(config, "user_id")
       }}
    end
  end

  @impl true
  def sync(%{raise_sync: true}) do
    raise "connector blew up"
  end

  def sync(%{fail_sync: message} = state) when is_binary(message) do
    {:error, message, state}
  end

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
