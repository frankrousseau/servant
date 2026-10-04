defmodule Servant.ApiTokens.Scopes do
  @moduledoc """
  Scope model for API tokens. The scopes use the app language
  (`app:notes:write`). `data:read`/`data:write` is the transversal wildcard:
  it covers every kind, the unmapped kinds included. `write` implies `read`
  on the same domain. Session tokens carry `nil` scopes, which means full
  access. This module is the single source of truth for the kind-to-domain
  mapping.
  """

  @app_domains ~w(notes checklists calendar contacts photos files finance trackers agent_memory)

  @kind_to_domain %{
    "note" => "notes",
    "checklist" => "checklists",
    "event" => "calendar",
    "contact" => "contacts",
    "photo" => "photos",
    "file" => "files",
    "account" => "finance",
    "balance" => "finance",
    "bank_tx" => "finance",
    "blockchain_tx" => "finance",
    "invoice" => "finance",
    "tracker" => "trackers",
    "tracker_log" => "trackers",
    "agent_memory" => "agent_memory"
  }

  @all Enum.flat_map(@app_domains, &["app:#{&1}:read", "app:#{&1}:write"]) ++
         ["data:read", "data:write", "data:read-binary"]

  @doc "Returns every valid scope string. The validation and the Settings UI use this list."
  def all, do: @all

  def valid?(scope), do: scope in @all

  @doc "Returns the scope string necessary for a domain/action. The 403 payloads use it."
  def scope_name("data", action), do: "data:#{action}"
  def scope_name(domain, action), do: "app:#{domain}:#{action}"

  @doc "Returns the domain that owns a kind, or nil for an unmapped kind (only `data:*` applies)."
  def kind_domain(kind), do: Map.get(@kind_to_domain, kind)

  @doc "nil scopes mean a session token, and a session token has full access."
  def can?(nil, _domain, _action), do: true

  def can?(scopes, "data", :read) when is_list(scopes),
    do: "data:read" in scopes or "data:write" in scopes

  def can?(scopes, "data", :write) when is_list(scopes), do: "data:write" in scopes

  def can?(scopes, domain, :read) when is_list(scopes) do
    "app:#{domain}:read" in scopes or "app:#{domain}:write" in scopes or
      can?(scopes, "data", :read)
  end

  def can?(scopes, domain, :write) when is_list(scopes) do
    "app:#{domain}:write" in scopes or "data:write" in scopes
  end

  @doc "Does the check at the kind level. Unmapped kinds fall back to the data domain."
  def can_kind?(scopes, kind, action) do
    can?(scopes, Map.get(@kind_to_domain, kind, "data"), action)
  end

  @doc """
  Raw file downloads (/files, /uploads) must have an explicit opt-in:
  `data:read` and `data:write` never imply the `data:read-binary` scope.
  """
  def can_read_binary?(nil), do: true
  def can_read_binary?(scopes) when is_list(scopes), do: "data:read-binary" in scopes

  @doc """
  Returns the kinds that a token can read. The result is `:all` for sessions
  and data-scoped tokens. If not, it is the mapped kinds of the readable
  domains of the token. This restricts the entry listings.
  """
  def readable_kinds(nil), do: :all

  def readable_kinds(scopes) do
    if can?(scopes, "data", :read) do
      :all
    else
      for {kind, domain} <- @kind_to_domain, can?(scopes, domain, :read), do: kind
    end
  end
end
