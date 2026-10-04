defmodule Servant.Dav do
  @moduledoc """
  WebDAV parts that the CalDAV and CardDAV contexts share: the entity tags
  for the entries and the collection tags calculated from them.
  """

  @doc "Returns a strong ETag calculated from the entry content."
  def etag(entry) do
    hash = :erlang.md5(:erlang.term_to_binary({entry.title, entry.occurred_at, entry.data}))
    ~s("#{Base.encode16(hash, case: :lower)}")
  end

  @doc "Returns the collection tag. It changes on each add, change or removal of a member."
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
