defmodule Servant.Connectors.ImportFileTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Data

  @vcf """
  BEGIN:VCARD
  VERSION:3.0
  FN:John Doe
  EMAIL:john@example.com
  UID:john-1
  END:VCARD
  """

  setup do
    base =
      Path.join(System.tmp_dir!(), "servant_import_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    prev_files = System.get_env("FILES_DIR")
    prev_tmp = System.get_env("TMP_DIR")
    System.put_env("FILES_DIR", Path.join(base, "files"))
    System.put_env("TMP_DIR", Path.join(base, "tmp"))

    on_exit(fn ->
      restore_env("FILES_DIR", prev_files)
      restore_env("TMP_DIR", prev_tmp)
      File.rm_rf(base)
    end)

    :ok
  end

  test "imports a vCard file into entries and records a sync log" do
    user = user_fixture()

    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "vcard",
        "name" => "Contacts"
      })

    upload = %Plug.Upload{
      path: write_tmp(@vcf),
      filename: "contacts.vcf",
      content_type: "text/vcard"
    }

    assert {:ok, result} = Connectors.import_file(user.id, config.id, upload)
    assert result.imported == 1
    assert result.total == 1
    assert Data.count_entries(user.id) == 1

    assert [log] = Connectors.list_sync_logs(config.id)
    assert log.status == "completed"
    assert log.entries_count == 1
  end

  test "rejects an unsupported connector type" do
    user = user_fixture()

    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "Not importable"
      })

    upload = %Plug.Upload{path: write_tmp("x"), filename: "x.txt", content_type: "text/plain"}

    assert {:error, :unsupported} = Connectors.import_file(user.id, config.id, upload)
  end

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "upload_#{System.unique_integer([:positive])}.tmp")
    File.write!(path, content)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
