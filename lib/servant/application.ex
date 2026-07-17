defmodule Servant.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ServantWeb.Telemetry,
        Servant.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:servant, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Servant.PubSub},
        {Registry, keys: :unique, name: Servant.Connectors.Registry},
        # DynamicSupervisor + Scheduler as a rest_for_one unit: a collapse of the
        # worker supervisor must re-run start_all_enabled, or connectors stop
        # syncing until the next full restart.
        Servant.Connectors.WorkerSupervisor,
        Servant.Audit.LogBuffer,
        Servant.Auth.Throttle,
        # Builder agent generations run here (fire-and-forget, run row = status)
        {Task.Supervisor, name: Servant.Agents.TaskSupervisor},
        Servant.Agents.Scheduler,
        # Start to serve requests, typically the last entry
        ServantWeb.Endpoint
      ] ++ Servant.Media.Backfill.child_specs()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Servant.Supervisor]

    with {:ok, _} = ok <- Supervisor.start_link(children, opts) do
      # Mirror error-level logs into the audit buffer (idempotent: re-adding
      # after a code reload returns {:error, :already_exist}, which is fine).
      _ =
        :logger.add_handler(:servant_audit_errors, Servant.Audit.ErrorLogHandler, %{level: :error})

      ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ServantWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
