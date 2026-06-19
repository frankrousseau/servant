defmodule Servant.Connectors.Connector do
  @moduledoc """
  Behaviour for connectors that sync external data sources.
  """

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback required_credentials() :: [atom()]
  @callback kind() :: String.t()
  @callback init(credentials :: map(), config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback sync(state :: term()) :: {:ok, [map()], state :: term()} | {:error, term(), state :: term()}

  @doc """
  Returns the list of schedules this connector supports.
  Defaults to all schedules except :continuous.
  """
  @callback supported_schedules() :: [String.t()]

  @doc """
  Returns the default schedule for this connector.
  Must be one of the supported schedules.
  """
  @callback default_schedule() :: String.t()

  @optional_callbacks [supported_schedules: 0, default_schedule: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour Servant.Connectors.Connector

      @impl Servant.Connectors.Connector
      def supported_schedules do
        ~w(on_demand every_5_minutes every_hour every_day every_week)
      end

      @impl Servant.Connectors.Connector
      def default_schedule, do: "every_hour"

      defoverridable supported_schedules: 0, default_schedule: 0
    end
  end
end
