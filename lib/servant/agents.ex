defmodule Servant.Agents do
  @moduledoc """
  Shared bookkeeping for AI agent runs. Every run records the model used,
  the tokens consumed and its duration (Sustainable AI manifesto). v1 only
  ships the "builder" type; explorer and recurrent agents will reuse this.
  """

  import Ecto.Query

  alias Servant.Agents.Run
  alias Servant.Repo

  def create_run(user_id, attrs) do
    %Run{user_id: user_id}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def get_run(user_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Run, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

  def list_runs(user_id, limit \\ 50) do
    # Tasks do not survive a server restart, so a run still "running" past
    # this point was interrupted, not actually running; 30 min is far beyond
    # the 300s AI timeout plus retry.
    stale_cutoff = DateTime.add(DateTime.utc_now(), -30, :minute)

    Run
    |> where(user_id: ^user_id)
    |> where(status: "running")
    |> where([r], r.inserted_at < ^stale_cutoff)
    |> Repo.update_all(set: [status: "error", error: "interrupted"])

    Run
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def complete_run(run, usage, duration_ms) do
    update_run(run, %{
      status: "ok",
      input_tokens: usage && usage.input_tokens,
      output_tokens: usage && usage.output_tokens,
      duration_ms: duration_ms
    })
  end

  def fail_run(run, error, usage \\ nil, duration_ms \\ nil) do
    update_run(run, %{
      status: "error",
      error: error |> to_string() |> String.slice(0, 2000),
      input_tokens: usage && usage.input_tokens,
      output_tokens: usage && usage.output_tokens,
      duration_ms: duration_ms
    })
  end

  defp update_run(run, attrs) do
    run |> Run.changeset(attrs) |> Repo.update()
  end
end
