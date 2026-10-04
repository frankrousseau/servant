defmodule Servant.Connectors.Connector do
  @moduledoc """
  Behaviour for connectors that sync external data sources.

  Note: the secrets and the settings are both in the `config` map of the
  connector (encrypted at rest for sensitive keys, see `Servant.Encrypted.Map`).
  The `credentials` argument of `init/2` is always `%{}` at this time. `init/2`
  reads the necessary values from `config` through `config_value/2,3`.
  `required_credentials/0` is advisory metadata only and gates nothing today.
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
  Returns the list of the schedules that this connector supports.
  The default is all the schedules except `"continuous"`.
  """
  @callback supported_schedules() :: [String.t()]

  @doc """
  Returns the default schedule for this connector.
  It must be one of the supported schedules.
  """
  @callback default_schedule() :: String.t()

  @doc """
  Returns the subset of the connector state to persist back into the stored
  config after a successful sync. Typically, it is an incremental cursor such as
  `last_block`/`last_signature` (or a rotated OAuth `refresh_token`). With the
  persisted subset, the connector resumes on restart and does not scan again
  from the start.

  The default is `%{}` (nothing persisted). The keys must be strings (the DB
  config maps use string keys).
  """
  @callback persisted_config(state :: term()) :: map()

  @optional_callbacks [supported_schedules: 0, default_schedule: 0, persisted_config: 1]

  @doc """
  Fetches a value from a connector config. Accepts the string form or the atom
  form of `key`. The configs come from the DB with string keys, but from the
  tests with atom keys. Returns `default` when neither key is present.
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
