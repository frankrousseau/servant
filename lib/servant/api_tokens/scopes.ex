defmodule Servant.ApiTokens.Scopes do
  @moduledoc """
  Scope model for API tokens. Scopes speak the app language
  (`app:notes:write`), with `data:read`/`data:write` as the transversal
  wildcard covering every kind including unmapped ones. `write` implies `read`
  on the same domain. Session tokens carry `nil` scopes, meaning full access.
  Single source of truth for the kind-to-domain mapping.
  """

  @app_domains ~w(notes checklists calendar contacts photos files finance trackers)

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
    "tracker_log" => "trackers"
  }

  @all Enum.flat_map(@app_domains, &["app:#{&1}:read", "app:#{&1}:write"]) ++
         ["data:read", "data:write", "data:read-binary"]

  @doc "Every valid scope string (drives validation and the Settings UI)."
  def all, do: @all

  def valid?(scope), do: scope in @all

  @doc "Scope string required for a domain/action, used in 403 payloads."
  def scope_name("data", action), do: "data:#{action}"
  def scope_name(domain, action), do: "app:#{domain}:#{action}"

  @doc "Domain owning a kind, or nil when unmapped (then only `data:*` applies)."
  def kind_domain(kind), do: Map.get(@kind_to_domain, kind)

  @doc "nil scopes = session token = full access."
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

  @doc "Kind-level check; unmapped kinds fall back to the data domain."
  def can_kind?(scopes, kind, action) do
    can?(scopes, Map.get(@kind_to_domain, kind, "data"), action)
  end

  @doc """
  Raw file downloads (/files, /uploads) need an explicit opt-in: the
  `data:read-binary` scope is never implied by `data:read` or `data:write`.
  """
  def can_read_binary?(nil), do: true
  def can_read_binary?(scopes) when is_list(scopes), do: "data:read-binary" in scopes

  @doc """
  Kinds a token may read: `:all` for sessions and data-scoped tokens,
  otherwise the mapped kinds of its readable domains (restricts entry listings).
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
