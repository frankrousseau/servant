defmodule Servant.Connectors.SyncTraceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Servant.Connectors.SyncTrace

  # Req.Test answers without Finch, so the tests replay the two events Finch
  # emits for one call, in the calling process.
  defp finch_call(status, result \\ {:ok, :response}) do
    request = Finch.build(:get, "https://api.example.com/v1/items?page=2&api_key=secret")

    if status do
      :telemetry.execute([:finch, :recv, :stop], %{duration: 0}, %{
        request: request,
        status: status,
        headers: []
      })
    end

    :telemetry.execute(
      [:finch, :request, :stop],
      %{duration: System.convert_time_unit(42, :millisecond, :native)},
      %{request: request, result: result}
    )
  end

  test "records a call with its status, never the query string" do
    SyncTrace.start()
    finch_call(200)
    trace = SyncTrace.finish()

    assert trace.http == [
             %{method: "GET", host: "api.example.com", path: "/v1/items", status: 200, ms: 42}
           ]

    refute inspect(trace) =~ "secret"
  end

  test "records a request that failed before any response" do
    SyncTrace.start()
    finch_call(nil, {:error, %RuntimeError{message: "connection refused"}})

    assert [%{status: nil, error: "connection refused"}] = SyncTrace.finish().http
  end

  test "records the lines logged during the run" do
    SyncTrace.start()
    capture_log(fn -> Logger.warning("page 3 of 7") end)

    assert [%{level: "warning", message: "page 3 of 7", at: at}] = SyncTrace.finish().logs
    assert {:ok, _, _} = DateTime.from_iso8601(at)
  end

  test "records nothing outside a trace" do
    finch_call(200)
    capture_log(fn -> Logger.warning("before the run") end)

    refute SyncTrace.active?()
    SyncTrace.start()
    assert %{http: [], logs: []} = SyncTrace.finish()
  end

  test "another process's calls stay out of the trace" do
    SyncTrace.start()
    Task.await(Task.async(fn -> finch_call(500) end))

    assert SyncTrace.finish().http == []
  end

  test "keeps 100 calls and counts the rest" do
    SyncTrace.start()
    for _ <- 1..105, do: finch_call(200)
    trace = SyncTrace.finish()

    assert length(trace.http) == 100
    assert trace.http_omitted == 5
  end

  test "summary/2 counts calls, failures and lines, and merges the details" do
    SyncTrace.start()
    finch_call(200)
    finch_call(503)
    finch_call(nil, {:error, %RuntimeError{message: "timeout"}})
    capture_log(fn -> Logger.warning("retrying") end)

    summary = SyncTrace.summary(SyncTrace.finish(), %{kinds: %{"note" => 2}})

    assert summary.http_count == 3
    assert summary.http_failed_count == 2
    assert summary.log_count == 1
    assert summary.details.kinds == %{"note" => 2}
    assert length(summary.details.http) == 3
  end
end
