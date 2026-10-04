defmodule Servant.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications.
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
        # DynamicSupervisor and Scheduler are one rest_for_one unit. A collapse
        # of the worker supervisor must run start_all_enabled again. If not,
        # the connectors do not sync until the next full restart.
        Servant.Connectors.EVM.RateLimiter,
        Servant.Connectors.WorkerSupervisor,
        Servant.Audit.LogBuffer,
        Servant.Auth.Throttle,
        # The generations of the builder agent run here. They are
        # fire-and-forget: the run row gives the status.
        {Task.Supervisor, name: Servant.Agents.TaskSupervisor},
        Servant.Agents.Scheduler,
        # Start to serve requests. This is usually the last entry.
        ServantWeb.Endpoint
      ] ++ Servant.Media.Backfill.child_specs()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options.
    opts = [strategy: :one_for_one, name: Servant.Supervisor]

    with {:ok, _} = ok <- Supervisor.start_link(children, opts) do
      # Mirror the error-level logs into the audit buffer. This is idempotent:
      # a second add after a code reload returns {:error, :already_exist}, and
      # that result is not a problem.
      _ =
        :logger.add_handler(:servant_audit_errors, Servant.Audit.ErrorLogHandler, %{level: :error})

      ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # each time the application gets an update.
  @impl true
  def config_change(changed, _new, removed) do
    ServantWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # The migrations run at boot in releases, and in each env that opts in
    # through :migrate_on_boot. Dev opts in. As a result, the boot migrates a
    # new DEV_DB file automatically. Test continues to run them through the
    # mix alias.
    System.get_env("RELEASE_NAME") == nil and
      not Application.get_env(:servant, :migrate_on_boot, false)
  end
end
