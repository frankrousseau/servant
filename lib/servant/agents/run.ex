defmodule Servant.Agents.Run do
  @moduledoc """
  One AI agent run. It records which action ran, on which model, what it
  used (tokens, duration) and how it stopped. v1 only has type "builder".
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :type, :string
    field :action, :string
    field :app_id, :string
    field :status, :string, default: "running"
    field :model, :string
    field :prompt, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :duration_ms, :integer
    field :error, :string

    belongs_to :agent, Servant.Agents.Agent
    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :type,
      :action,
      :app_id,
      :status,
      :model,
      :prompt,
      :input_tokens,
      :output_tokens,
      :duration_ms,
      :error
    ])
    |> validate_required([:type, :action, :status])
    |> validate_inclusion(:status, ~w(running ok error))
  end
end
