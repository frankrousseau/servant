defmodule Servant.Audit do
  @moduledoc """
  System introspection for the Audit page: the machine resources (CPU, RAM),
  the resources that the server and its connector workers use, and the disk
  usage.

  The module is Linux-first. It reads `/proc` and the cgroup files. This is
  sufficient for bare-metal deployments and for Docker deployments. Each
  probe returns `nil` when its source is missing (for example macOS in
  development). As a result, the endpoint never crashes on an unusual host.
  """

  import Ecto.Query

  alias Servant.Connectors.ConnectorConfig
  alias Servant.Repo
  alias Servant.Storage

  def system_stats do
    %{
      cpu: cpu_stats(),
      memory: memory_stats(),
      server: server_stats(),
      workers: worker_stats(),
      disk: disk_stats()
    }
  end

  # ---- CPU ----

  defp cpu_stats do
    load =
      with {:ok, content} <- File.read("/proc/loadavg"),
           [l1, l5, l15 | _] <- String.split(content) do
        %{avg1: parse_float(l1), avg5: parse_float(l5), avg15: parse_float(l15)}
      else
        _ -> nil
      end

    %{
      cores: :erlang.system_info(:logical_processors_online),
      schedulers: :erlang.system_info(:schedulers_online),
      load: load
    }
  end

  # ---- machine + container memory ----

  defp memory_stats do
    meminfo = read_meminfo()

    %{
      total_bytes: meminfo[:total],
      available_bytes: meminfo[:available],
      # In Docker, the real budget is the cgroup limit, not the MemTotal of
      # the host. Read v2 first, then v1. The value is nil when there is no
      # limit or no file.
      cgroup_limit_bytes:
        cgroup_bytes(["/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"]),
      cgroup_used_bytes:
        cgroup_bytes([
          "/sys/fs/cgroup/memory.current",
          "/sys/fs/cgroup/memory/memory.usage_in_bytes"
        ])
    }
  end

  defp read_meminfo do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/^(MemTotal|MemAvailable):\s+(\d+) kB/, line) do
            [_, "MemTotal", kb] -> Map.put(acc, :total, String.to_integer(kb) * 1024)
            [_, "MemAvailable", kb] -> Map.put(acc, :available, String.to_integer(kb) * 1024)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  # cgroup v2 writes "max" when there is no limit. v1 uses a very large
  # number. Both mean "no limit" and give nil.
  defp cgroup_bytes(paths) do
    Enum.find_value(paths, fn path ->
      with {:ok, content} <- File.read(path),
           {n, _} when n < 1_000_000_000_000_000 <- Integer.parse(String.trim(content)) do
        n
      else
        _ -> nil
      end
    end)
  end

  # ---- the server's own OS process ----

  defp server_stats do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      os_pid: System.pid(),
      rss_bytes: read_own_rss(),
      beam_memory_bytes: :erlang.memory(:total),
      process_count: :erlang.system_info(:process_count),
      uptime_seconds: div(uptime_ms, 1000)
    }
  end

  defp read_own_rss do
    with {:ok, content} <- File.read("/proc/self/status"),
         [_, kb] <- Regex.run(~r/VmRSS:\s+(\d+) kB/, content) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  # ---- connector workers ----

  defp worker_stats do
    entries =
      Registry.select(Servant.Connectors.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    config_ids = Enum.map(entries, fn {{_user_id, config_id}, _pid} -> config_id end)

    names =
      from(c in ConnectorConfig,
        where: c.id in ^config_ids,
        select: {c.id, {c.connector_type, c.name}}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(entries, fn {{user_id, config_id}, pid} ->
      info = Process.info(pid, [:memory, :message_queue_len, :reductions]) || []
      {type, name} = Map.get(names, config_id, {nil, nil})

      %{
        user_id: user_id,
        config_id: config_id,
        connector_type: type,
        name: name,
        memory_bytes: info[:memory],
        message_queue_len: info[:message_queue_len],
        reductions: info[:reductions]
      }
    end)
  end

  # ---- disk ----

  defp disk_stats do
    files_root = Storage.files_root()
    db_path = Application.get_env(:servant, Servant.Repo)[:database]

    %{
      volume: df(files_root),
      data_bytes: du(files_root),
      database_bytes: db_size(db_path)
    }
  end

  # Returns the space on the filesystem that holds the data dir. In Docker,
  # that is the mounted volume. The volume fills up, not the host root.
  defp df(path) do
    case System.cmd("df", ["-kP", path], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_fs, total, used, avail | rest] ->
            %{
              total_bytes: String.to_integer(total) * 1024,
              used_bytes: String.to_integer(used) * 1024,
              available_bytes: String.to_integer(avail) * 1024,
              mount: List.last(rest)
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp du(path) do
    if File.dir?(path) do
      case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
        {out, 0} ->
          case Integer.parse(out) do
            {kb, _} -> kb * 1024
            :error -> nil
          end

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  end

  defp db_size(nil), do: nil

  defp db_size(path) do
    # SQLite uses the db file and its -wal and -shm siblings.
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.map(fn p ->
      case File.stat(p) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end
end
