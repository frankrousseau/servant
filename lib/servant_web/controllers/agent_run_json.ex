defmodule ServantWeb.AgentRunJSON do
  @moduledoc "JSON shape of an agent run, shared by the agents and apps controllers."

  def run_json(run) do
    %{
      id: run.id,
      type: run.type,
      action: run.action,
      agent_id: run.agent_id,
      app_id: run.app_id,
      status: run.status,
      model: run.model,
      prompt: run.prompt,
      input_tokens: run.input_tokens,
      output_tokens: run.output_tokens,
      duration_ms: run.duration_ms,
      error: run.error,
      inserted_at: run.inserted_at
    }
  end
end
