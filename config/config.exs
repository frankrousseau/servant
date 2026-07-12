# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :servant,
  ecto_repos: [Servant.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Open self-registration. Override at runtime with REGISTRATION_ENABLED=false
  # (see config/runtime.exs) once your accounts are created.
  registration_enabled: true

# Configure the endpoint
config :servant, ServantWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ServantWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Servant.PubSub,
  live_view: [signing_salt: "UwSj8HI6"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# IANA timezone database (day bucketing of aggregates in the user's timezone)
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
