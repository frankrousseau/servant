defmodule Servant.Connectors.Connector do
  @moduledoc """
  Behaviour for connectors that sync external data sources.

  Note: secrets and settings both live in the connector's `config` map
  (encrypted at rest for sensitive keys — see `Servant.Encrypted.Map`). The
  `credentials` argument to `init/2` is currently always `%{}`; `init/2` reads
  what it needs from `config` via `config_value/2,3`. `required_credentials/0`
  is advisory metadata only and does not gate anything today.
  """

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback required_credentials() :: [atom()]
  @callback kind() :: String.t()
  @callback init(credentials :: map(), config :: map()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback sync(state :: term()) ::
              {:ok, [map()], state :: term()} | {:error, term(), state :: term()}

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

  @doc """
  Returns the subset of connector state that must be persisted back into the
  stored config after a successful sync — typically an incremental cursor like
  `last_block`/`last_signature` (or a rotated OAuth `refresh_token`). Persisting
  it lets the connector resume instead of re-scanning from scratch on restart.

  Defaults to `%{}` (nothing persisted). Keys should be strings (DB config maps
  use string keys).
  """
  @callback persisted_config(state :: term()) :: map()

  @optional_callbacks [supported_schedules: 0, default_schedule: 0, persisted_config: 1]

  @doc """
  Fetches a value from a connector config, accepting either the string or
  atom form of `key` (configs come from the DB with string keys but from
  tests with atom keys). Returns `default` when neither key is present.
  """
  def config_value(config, key, default \\ nil) when is_binary(key) do
    Map.get(config, key) || Map.get(config, safe_existing_atom(key)) || default
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Servant.Connectors.Connector

      import Servant.Connectors.Connector, only: [config_value: 2, config_value: 3]

      @impl Servant.Connectors.Connector
      def supported_schedules do
        ~w(on_demand every_5_minutes every_hour every_day every_week)
      end

      @impl Servant.Connectors.Connector
      def default_schedule, do: "every_hour"

      @impl Servant.Connectors.Connector
      def persisted_config(_state), do: %{}

      defoverridable supported_schedules: 0, default_schedule: 0, persisted_config: 1
    end
  end
end
