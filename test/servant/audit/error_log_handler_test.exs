defmodule Servant.Audit.ErrorLogHandlerTest do
  use ExUnit.Case, async: false

  alias Servant.Audit.ErrorLogHandler
  alias Servant.Audit.LogBuffer

  defp log(msg, meta \\ %{}) do
    before = length(LogBuffer.error_logs())
    ErrorLogHandler.log(%{level: :error, msg: msg, meta: meta}, %{})

    # The buffer records through a cast. A call flushes it.
    entries = LogBuffer.error_logs()
    assert length(entries) == before + 1
    hd(entries)
  end

  test "records a plain string message with its level and time" do
    entry = log({:string, "boom"}, %{time: 1_760_000_000_000_000})

    assert entry.message == "boom"
    assert entry.level == "error"
    assert entry.at == "2025-10-09T08:53:20.000000Z"
  end

  test "falls back to now when the event carries no timestamp" do
    entry = log({:string, "no time"})
    assert {:ok, _dt, _} = DateTime.from_iso8601(entry.at)
  end

  test "formats a format-and-args message" do
    entry = log({~c"connector ~s failed: ~p", [~c"ovh", :timeout]})
    assert entry.message == "connector ovh failed: timeout"
  end

  # OTP crash reports arrive as a report plus a callback that renders it.
  test "renders a report through its report_cb" do
    report = %{reason: :badarg}
    callback = fn %{reason: reason} -> {~c"crashed: ~p", [reason]} end

    entry = log({:report, report}, %{report_cb: callback})
    assert entry.message == "crashed: badarg"
  end

  test "inspects a report that brings no callback" do
    entry = log({:report, %{reason: :badarg}})
    assert entry.message =~ "reason: :badarg"
  end

  test "truncates a runaway message" do
    entry = log({:string, String.duplicate("x", 5_000)})
    assert String.length(entry.message) == 2_000
  end

  # If a handler raises, the full logger goes down with it. Instead, this
  # handler swallows the event.
  test "a message it cannot format never raises" do
    before = length(LogBuffer.error_logs())

    assert :ok =
             ErrorLogHandler.log(
               %{level: :error, msg: {:report, %{}}, meta: %{report_cb: fn _ -> :nope end}},
               %{}
             )

    assert length(LogBuffer.error_logs()) == before
  end
end
