defmodule Servant.Audit.LogBufferTest do
  use ExUnit.Case, async: true

  alias Servant.Audit.LogBuffer

  setup do
    pid = start_supervised!({LogBuffer, name: :"buffer_#{System.unique_integer([:positive])}"})
    %{buffer: pid}
  end

  test "records access and error entries in separate buffers, newest first", %{buffer: buffer} do
    LogBuffer.record_access(%{path: "/a"}, buffer)
    LogBuffer.record_access(%{path: "/b"}, buffer)
    LogBuffer.record_error(%{message: "boom"}, buffer)
    _ = :sys.get_state(buffer)

    assert [%{path: "/b"}, %{path: "/a"}] = LogBuffer.access_logs(buffer)
    assert [%{message: "boom"}] = LogBuffer.error_logs(buffer)
  end

  test "caps each buffer at 500 entries", %{buffer: buffer} do
    for i <- 1..510, do: LogBuffer.record_access(%{n: i}, buffer)
    _ = :sys.get_state(buffer)

    logs = LogBuffer.access_logs(buffer)
    assert length(logs) == 500
    assert hd(logs) == %{n: 510}
    assert List.last(logs) == %{n: 11}
  end
end
