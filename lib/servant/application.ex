defmodule Servant.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ServantWeb.Telemetry,
      Servant.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:servant, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: Servant.PubSub},
      {Registry, keys: :unique, name: Servant.Connectors.Registry},
      {DynamicSupervisor, name: Servant.Connectors.Supervisor, strategy: :one_for_one},
      Servant.Connectors.Scheduler,
      # Start to serve requests, typically the last entry
      ServantWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Servant.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ServantWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
