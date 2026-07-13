defmodule Servant.Dav do
  @moduledoc """
  Shared WebDAV bits between the CalDAV and CardDAV contexts: entity tags
  for entries and collection tags derived from them.
  """

  @doc "Strong ETag derived from the entry content."
  def etag(entry) do
    hash = :erlang.md5(:erlang.term_to_binary({entry.title, entry.occurred_at, entry.data}))
    ~s("#{Base.encode16(hash, case: :lower)}")
  end

  @doc "Collection tag: changes whenever any member is added, changed or removed."
  def ctag(entries) do
    digest =
      entries
      |> Enum.map(&"#{&1.id}#{etag(&1)}")
      |> Enum.sort()
      |> Enum.join()
      |> then(&:erlang.md5/1)

    Base.encode16(digest, case: :lower)
  end
end
