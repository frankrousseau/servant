# Scoped API Tokens + OpenAPI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Agents and scripts can act on Servant data through opaque `srv_` API tokens restricted by app-level scopes, and the whole REST API is described by an OpenAPI spec served at `/api/openapi.json` (SwaggerUI at `/api/docs`).

**Architecture:** Opaque tokens hashed (SHA-256) in a new `api_tokens` table, recognized by the existing `ServantWeb.Auth` plug via the `srv_` prefix. Scopes are `app:<domain>:<read|write>` plus the `data:<read|write>` wildcard; a single module maps entry kinds to domains. Enforcement is a `Scope` plug for whole-domain controllers, per-kind checks in `EntryController`, and a `SessionOnly` plug for surfaces tokens must never reach. OpenAPI is generated in code with `open_api_spex`, with an anti-drift test comparing router routes to spec paths.

**Tech Stack:** Elixir/Phoenix 1.8 (API-only), Ecto + SQLite (`ecto_sqlite3`), `open_api_spex ~> 3.22`, Vue 3 SPA (Settings UI).

**Design doc:** `docs/plans/2026-07-10-api-tokens-openapi-design.md` (validated). Read it first.

**Conventions that apply everywhere (from AGENTS.md):**
- No em dashes anywhere, use plain hyphens.
- `@moduledoc` right after `defmodule`; directives ordered `use`, `import`, `alias` (alphabetical).
- Never nest two modules in one file.
- In tests, actual value left of the operator: `assert actual == expected`.
- Run `mix format` before each commit; `mix precommit` at the end.
- Frontend: Prettier via `cd frontend && npm run format`; Vue SFC order script/template/style.

**Known v1 limits (do NOT fix in this plan):** raw file bytes under `/files/*` stay cookie/session-authenticated (an API token can read `photo` entries but not download the image bytes); request validation from the OpenAPI spec is out of scope; SwaggerUI loads its JS/CSS from a CDN (doc page only, operator convenience).

---

## Phase A: token model and authentication

### Task 1: `Servant.ApiTokens.Scopes` (pure scope logic)

**Files:**
- Create: `lib/servant/api_tokens/scopes.ex`
- Test: `test/servant/api_tokens/scopes_test.exs`

**Step 1: Write the failing tests**

```elixir
defmodule Servant.ApiTokens.ScopesTest do
  use ExUnit.Case, async: true

  alias Servant.ApiTokens.Scopes

  describe "all/0 and valid?/1" do
    test "contains app scopes and data scopes" do
      assert "app:notes:read" in Scopes.all()
      assert "app:trackers:write" in Scopes.all()
      assert "data:read" in Scopes.all()
      assert Scopes.valid?("app:finance:read") == true
      assert Scopes.valid?("finance:read") == false
      assert Scopes.valid?("app:bogus:read") == false
    end
  end

  describe "can?/3" do
    test "nil scopes (session) can do everything" do
      assert Scopes.can?(nil, "notes", :write) == true
      assert Scopes.can?(nil, "data", :write) == true
    end

    test "read scope grants read only" do
      assert Scopes.can?(["app:notes:read"], "notes", :read) == true
      assert Scopes.can?(["app:notes:read"], "notes", :write) == false
    end

    test "write implies read on the same domain" do
      assert Scopes.can?(["app:trackers:write"], "trackers", :read) == true
      assert Scopes.can?(["app:trackers:write"], "trackers", :write) == true
    end

    test "scopes do not leak across domains" do
      assert Scopes.can?(["app:trackers:write"], "finance", :read) == false
      assert Scopes.can?(["app:notes:read"], "checklists", :read) == false
    end

    test "data scopes cover app domains" do
      assert Scopes.can?(["data:read"], "finance", :read) == true
      assert Scopes.can?(["data:read"], "finance", :write) == false
      assert Scopes.can?(["data:write"], "notes", :write) == true
      assert Scopes.can?(["data:write"], "data", :read) == true
    end
  end

  describe "can_kind?/3" do
    test "maps kinds to their domain" do
      assert Scopes.can_kind?(["app:trackers:write"], "tracker_log", :write) == true
      assert Scopes.can_kind?(["app:trackers:write"], "bank_tx", :read) == false
      assert Scopes.can_kind?(["app:finance:read"], "balance", :read) == true
    end

    test "unmapped kinds require the data scope" do
      assert Scopes.can_kind?(["app:notes:write"], "health", :read) == false
      assert Scopes.can_kind?(["data:read"], "health", :read) == true
      assert Scopes.can_kind?(["data:write"], "prefs", :write) == true
    end
  end

  describe "readable_kinds/1" do
    test "session and data tokens read all kinds" do
      assert Scopes.readable_kinds(nil) == :all
      assert Scopes.readable_kinds(["data:read"]) == :all
    end

    test "app tokens read only their domains' kinds" do
      kinds = Scopes.readable_kinds(["app:finance:read", "app:trackers:write"])
      assert Enum.sort(kinds) ==
               Enum.sort(~w(account balance bank_tx blockchain_tx invoice tracker tracker_log))
    end
  end

  describe "scope_name/2" do
    test "formats app and data scopes" do
      assert Scopes.scope_name("notes", :write) == "app:notes:write"
      assert Scopes.scope_name("data", :read) == "data:read"
    end
  end
end
```

**Step 2: Run to verify failure**

Run: `mix test test/servant/api_tokens/scopes_test.exs`
Expected: FAIL (module `Servant.ApiTokens.Scopes` is not available)

**Step 3: Implement**

```elixir
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
         ["data:read", "data:write"]

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
```

**Step 4: Run tests**

Run: `mix test test/servant/api_tokens/scopes_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
mix format
git add lib/servant/api_tokens/scopes.ex test/servant/api_tokens/scopes_test.exs
git commit -m "API token scopes: app-prefixed domains + data wildcard"
```

---

### Task 2: migration, schema and `Servant.ApiTokens` context

**Files:**
- Create: migration via `mix ecto.gen.migration create_api_tokens`
- Create: `lib/servant/api_tokens/api_token.ex`
- Create: `lib/servant/api_tokens.ex`
- Test: `test/servant/api_tokens_test.exs`

**Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_api_tokens`

Fill it with:

```elixir
defmodule Servant.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :prefix, :string, null: false
      # ecto_sqlite3 stores {:array, :string} as JSON text
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
```

**Step 2: Write the failing tests**

```elixir
defmodule Servant.ApiTokensTest do
  use Servant.DataCase, async: true

  alias Servant.ApiTokens
  alias Servant.ApiTokens.ApiToken

  defp user, do: Servant.Fixtures.user_fixture()

  describe "create_token/2" do
    test "returns the struct and a srv_ plaintext, stores only the hash" do
      u = user()

      {:ok, token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["app:notes:read"]})

      assert String.starts_with?(plaintext, "srv_")
      assert token.prefix == String.slice(plaintext, 0, 8)
      assert token.token_hash != plaintext
      refute String.contains?(token.token_hash, plaintext)
      assert token.scopes == ["app:notes:read"]
    end

    test "rejects unknown scopes, empty scopes and missing name" do
      u = user()

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_token(u.id, %{"name" => "x", "scopes" => ["notes:read"]})

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_token(u.id, %{"name" => "x", "scopes" => []})

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_token(u.id, %{"scopes" => ["data:read"]})
    end
  end

  describe "authenticate/1" do
    test "valid plaintext returns the user and scopes" do
      u = user()

      {:ok, _token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["data:read"]})

      assert {:ok, auth_user, ["data:read"]} = ApiTokens.authenticate(plaintext)
      assert auth_user.id == u.id
    end

    test "unknown, malformed and expired tokens fail" do
      u = user()
      assert ApiTokens.authenticate("srv_bogus") == :error
      assert ApiTokens.authenticate("not-a-token") == :error

      past = DateTime.add(DateTime.utc_now(:second), -60, :second)

      {:ok, _t, plaintext} =
        ApiTokens.create_token(u.id, %{
          "name" => "old",
          "scopes" => ["data:read"],
          "expires_at" => DateTime.to_iso8601(past)
        })

      assert ApiTokens.authenticate(plaintext) == :error
    end

    test "authenticate touches last_used_at" do
      u = user()

      {:ok, token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["data:read"]})

      assert token.last_used_at == nil
      {:ok, _, _} = ApiTokens.authenticate(plaintext)
      assert %DateTime{} = Repo.get!(ApiToken, token.id).last_used_at
    end
  end

  describe "list_tokens/1 and delete_token/2" do
    test "lists own tokens only, deletes own token, revoked token stops working" do
      u1 = user()
      u2 = user()
      {:ok, t1, plaintext} = ApiTokens.create_token(u1.id, %{"name" => "a", "scopes" => ["data:read"]})
      {:ok, _t2, _} = ApiTokens.create_token(u2.id, %{"name" => "b", "scopes" => ["data:read"]})

      assert Enum.map(ApiTokens.list_tokens(u1.id), & &1.id) == [t1.id]

      # cannot delete someone else's token
      assert ApiTokens.delete_token(u2.id, t1.id) == {:error, :not_found}

      assert {:ok, _} = ApiTokens.delete_token(u1.id, t1.id)
      assert ApiTokens.authenticate(plaintext) == :error
    end
  end
end
```

**Step 3: Run to verify failure**

Run: `mix test test/servant/api_tokens_test.exs`
Expected: FAIL (modules not available)

**Step 4: Implement the schema**

`lib/servant/api_tokens/api_token.ex`:

```elixir
defmodule Servant.ApiTokens.ApiToken do
  @moduledoc "A scoped, individually revocable API token. Only the SHA-256 hash is stored."

  use Ecto.Schema

  import Ecto.Changeset

  alias Servant.ApiTokens.Scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :prefix, :string
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  # user_id, token_hash and prefix are set programmatically by the context,
  # never cast from params.
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :scopes, :expires_at])
    |> validate_required([:name, :scopes])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_scopes()
  end

  defp validate_scopes(changeset) do
    changeset
    |> validate_length(:scopes, min: 1)
    |> validate_change(:scopes, fn :scopes, scopes ->
      case Enum.reject(scopes, &Scopes.valid?/1) do
        [] -> []
        bad -> [scopes: "unknown scopes: #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  @doc "JSON shape for the management API. Never includes the hash."
  def to_json(%__MODULE__{} = t) do
    %{
      id: t.id,
      name: t.name,
      prefix: t.prefix,
      scopes: t.scopes,
      expires_at: t.expires_at,
      last_used_at: t.last_used_at,
      inserted_at: t.inserted_at
    }
  end
end
```

**Step 5: Implement the context**

`lib/servant/api_tokens.ex`:

```elixir
defmodule Servant.ApiTokens do
  @moduledoc """
  Scoped API tokens for agents and scripts. The plaintext (`srv_` prefixed) is
  returned exactly once at creation; only its SHA-256 hash lands in the
  database. Tokens are individually revocable and independent of the session
  `token_version` (revoking an agent does not log the user out).
  """

  import Ecto.Query

  alias Servant.Accounts
  alias Servant.ApiTokens.ApiToken
  alias Servant.Repo

  @prefix "srv_"
  # last_used_at is refreshed at most once per interval, not on every request
  @touch_interval_s 60

  def list_tokens(user_id) do
    ApiToken
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc "Creates a token. Returns `{:ok, struct, plaintext}`; the plaintext is shown once."
  def create_token(user_id, attrs) do
    plaintext = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    changeset =
      %ApiToken{}
      |> ApiToken.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user_id)
      |> Ecto.Changeset.put_change(:token_hash, hash(plaintext))
      |> Ecto.Changeset.put_change(:prefix, String.slice(plaintext, 0, 8))

    case Repo.insert(changeset) do
      {:ok, api_token} -> {:ok, api_token, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete_token(user_id, id) do
    case Repo.get_by(ApiToken, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  @doc """
  Authenticates a plaintext API token: `{:ok, user, scopes}` when the hash is
  known, the token is not expired and the user still exists.
  """
  def authenticate(@prefix <> _ = plaintext) do
    with %ApiToken{} = token <- Repo.get_by(ApiToken, token_hash: hash(plaintext)),
         false <- expired?(token),
         user when not is_nil(user) <- Accounts.get_user(token.user_id) do
      touch(token)
      {:ok, user, token.scopes}
    else
      _ -> :error
    end
  end

  def authenticate(_), do: :error

  defp expired?(%ApiToken{expires_at: nil}), do: false
  defp expired?(%ApiToken{expires_at: at}), do: DateTime.compare(at, DateTime.utc_now()) == :lt

  defp touch(%ApiToken{} = token) do
    now = DateTime.utc_now(:second)
    stale = DateTime.add(now, -@touch_interval_s, :second)

    if is_nil(token.last_used_at) or DateTime.compare(token.last_used_at, stale) == :lt do
      ApiToken
      |> where(id: ^token.id)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  defp hash(plaintext) do
    Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower)
  end
end
```

**Step 6: Migrate and run tests**

Run: `mix ecto.migrate && mix test test/servant/api_tokens_test.exs test/servant/api_tokens/scopes_test.exs`
Expected: PASS. If `{:array, :string}` gives trouble under ecto_sqlite3 (it should not; arrays are stored as JSON text), fall back to `:map` storage with a `{:array, :string}` schema field is NOT valid; instead ask before improvising.

**Step 7: Commit**

```bash
mix format
git add priv/repo/migrations/*create_api_tokens.exs lib/servant/api_tokens.ex lib/servant/api_tokens/api_token.ex test/servant/api_tokens_test.exs
git commit -m "api_tokens table + context: hashed opaque tokens, expiry, revocation"
```

---

### Task 3: recognize `srv_` tokens in the Auth plug

**Files:**
- Modify: `lib/servant_web/auth.ex`
- Modify: `test/support/conn_case.ex` (new helper)
- Test: `test/servant_web/auth/api_token_auth_test.exs`

**Step 1: Add the ConnCase helper**

In `test/support/conn_case.ex`, after `register_and_log_in_user/2`:

```elixir
@doc """
Registers a user, creates an API token with `scopes` and returns
`{conn, user}` with the token's plaintext set as Bearer header.
"""
def register_and_log_in_api_token(conn, scopes, attrs \\ %{}) do
  user = Servant.Fixtures.user_fixture(attrs)

  {:ok, _token, plaintext} =
    Servant.ApiTokens.create_token(user.id, %{"name" => "test token", "scopes" => scopes})

  {Plug.Conn.put_req_header(conn, "authorization", "Bearer #{plaintext}"), user}
end
```

**Step 2: Write the failing tests**

`test/servant_web/auth/api_token_auth_test.exs` (use `GET /api/entries` as the probe route):

```elixir
defmodule ServantWeb.Auth.ApiTokenAuthTest do
  use ServantWeb.ConnCase, async: false

  alias Servant.Auth.Throttle

  setup do
    # failed lookups feed the per-IP throttle; keep tests independent
    on_exit(fn -> Throttle.reset("api_token:127.0.0.1") end)
    :ok
  end

  test "a valid API token authenticates", %{conn: conn} do
    {conn, _user} = register_and_log_in_api_token(conn, ["data:read"])
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 200)
  end

  test "an unknown srv_ token gets 401 and records a throttle failure", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer srv_unknown")
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 401)["error"] == "Unauthorized"
  end

  test "too many failed srv_ attempts get 429", %{conn: conn} do
    for _ <- 1..10, do: Throttle.record_failure("api_token:127.0.0.1")

    conn = put_req_header(conn, "authorization", "Bearer srv_unknown")
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 429)["error"] == "Too many attempts"
  end

  test "session tokens keep full access (api_scopes nil)", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 200)
  end
end
```

**Step 3: Run to verify failure**

Run: `mix test test/servant_web/auth/api_token_auth_test.exs`
Expected: the 401/429 tests fail (an `srv_` bearer currently falls through to `Phoenix.Token.verify` and 401s, so the "valid token" test fails; the 429 path does not exist yet).

**Step 4: Implement**

In `lib/servant_web/auth.ex`, replace `call/2` and add the private helpers (keep everything else):

```elixir
def call(conn, _opts) do
  case fetch_token(conn) do
    {:ok, token} -> authenticate_request(conn, token)
    :error -> unauthorized(conn)
  end
end

# API tokens (srv_ prefix): DB lookup by hash, scopes attached. Failed lookups
# feed the per-IP throttle so token values can't be brute forced.
defp authenticate_request(conn, "srv_" <> _ = token) do
  throttle_key = "api_token:" <> ip_string(conn)

  with :ok <- Servant.Auth.Throttle.check(throttle_key),
       {:ok, user, scopes} <- Servant.ApiTokens.authenticate(token) do
    Servant.Auth.Throttle.reset(throttle_key)

    conn
    |> assign(:current_user, user)
    |> assign(:api_scopes, scopes)
  else
    {:error, retry_after} ->
      conn
      |> put_status(:too_many_requests)
      |> Phoenix.Controller.json(%{error: "Too many attempts", retry_after: retry_after})
      |> halt()

    :error ->
      Servant.Auth.Throttle.record_failure(throttle_key)
      unauthorized(conn)
  end
end

# Session tokens (Phoenix.Token): full access, api_scopes stays nil.
defp authenticate_request(conn, token) do
  case authenticate_token(conn, token) do
    {:ok, user} ->
      conn
      |> assign(:current_user, user)
      |> assign(:api_scopes, nil)

    :error ->
      unauthorized(conn)
  end
end

defp unauthorized(conn) do
  conn
  |> put_status(:unauthorized)
  |> Phoenix.Controller.json(%{error: "Unauthorized"})
  |> halt()
end

defp ip_string(conn) do
  conn.remote_ip |> :inet.ntoa() |> to_string()
end
```

Note: `AuthController` already formats IPs for its own throttle keys; check
`lib/servant_web/controllers/auth_controller.ex` and reuse its helper if one is
importable, otherwise keep the local `ip_string/1` above.

**Step 5: Run tests**

Run: `mix test test/servant_web/auth/api_token_auth_test.exs && mix test`
Expected: PASS (full suite: nothing else should notice, session behavior unchanged)

**Step 6: Commit**

```bash
mix format
git add lib/servant_web/auth.ex test/support/conn_case.ex test/servant_web/auth/api_token_auth_test.exs
git commit -m "Auth plug: authenticate srv_ API tokens with scopes + IP throttle"
```

---

## Phase B: enforcement

### Task 4: `Scope` and `SessionOnly` plugs + router restructure

**Files:**
- Create: `lib/servant_web/plugs/scope.ex`
- Create: `lib/servant_web/plugs/session_only.ex`
- Modify: `lib/servant_web/router.ex`
- Test: `test/servant_web/plugs/session_only_test.exs`

**Step 1: Write the failing tests**

```elixir
defmodule ServantWeb.Plugs.SessionOnlyTest do
  use ServantWeb.ConnCase, async: false

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_api_token(conn, ["data:write"])
    %{conn: conn, user: user}
  end

  test "API tokens cannot reach auth endpoints", %{conn: conn} do
    conn = get(conn, ~p"/api/auth/me")
    assert json_response(conn, 403)
  end

  test "API tokens cannot manage connectors", %{conn: conn} do
    conn = get(conn, ~p"/api/connectors")
    assert json_response(conn, 403)
  end

  test "API tokens cannot start a media backfill", %{conn: conn} do
    conn = post(conn, ~p"/api/entries/backfill_media")
    assert json_response(conn, 403)
  end

  test "sessions still reach session-only endpoints" do
    {conn, _user} = register_and_log_in_user(build_conn())
    conn = get(conn, ~p"/api/auth/me")
    assert json_response(conn, 200)
  end
end
```

**Step 2: Run to verify failure**

Run: `mix test test/servant_web/plugs/session_only_test.exs`
Expected: FAIL (API token currently gets 200 everywhere)

**Step 3: Implement the plugs**

`lib/servant_web/plugs/scope.ex`:

```elixir
defmodule ServantWeb.Plugs.Scope do
  @moduledoc """
  Enforces API-token scopes for a controller (optionally per action via
  `plug ... when action in [...]`). Session tokens (`api_scopes: nil`) always
  pass. GET/HEAD require `<domain>:read`, everything else `<domain>:write`.
  """

  import Plug.Conn

  alias Servant.ApiTokens.Scopes

  def init(opts), do: opts

  def call(conn, opts) do
    domain = Keyword.fetch!(opts, :domain)
    action = if conn.method in ["GET", "HEAD"], do: :read, else: :write

    if Scopes.can?(conn.assigns[:api_scopes], domain, action) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{
        error: "Insufficient scope",
        required: Scopes.scope_name(domain, action)
      })
      |> halt()
    end
  end
end
```

`lib/servant_web/plugs/session_only.ex`:

```elixir
defmodule ServantWeb.Plugs.SessionOnly do
  @moduledoc """
  Rejects API tokens. Account management, connectors, audit and token
  management are reserved to interactive sessions so a leaked token can't
  escalate (create tokens, change the password, read other domains).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if is_nil(conn.assigns[:api_scopes]) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{error: "Session required (API tokens not allowed)"})
      |> halt()
    end
  end
end
```

**Step 4: Restructure the router**

Replace the `/api` scope in `lib/servant_web/router.ex` with nested scopes (cumulative `pipe_through` can't express "token zone then session zone" linearly). Add the pipeline:

```elixir
pipeline :session_only do
  plug ServantWeb.Plugs.SessionOnly
end
```

New layout (moves, no route additions yet; `backfill_media` moves into the session-only zone):

```elixir
scope "/api", ServantWeb do
  pipe_through :api

  get "/auth/config", AuthController, :config
  post "/auth/register", AuthController, :register
  post "/auth/login", AuthController, :login
  post "/auth/totp/verify", AuthController, :totp_verify

  scope "/" do
    pipe_through :auth

    # Reachable by scoped API tokens; scope checks live in the controllers.
    get "/entries/kinds", EntryController, :kinds
    get "/entries/sources", EntryController, :sources
    get "/entries/stats", EntryController, :stats
    get "/entries/stats/daily", EntryController, :daily_stats
    resources "/entries", EntryController, except: [:new, :edit]

    get "/notes/mentioning/:entry_id", NotesController, :mentioning
    get "/notes/:id/backlinks", NotesController, :backlinks
    resources "/notes", NotesController, except: [:new, :edit]

    get "/apps", AppController, :index

    post "/uploads", UploadController, :create

    get "/export/entries", ExportController, :entries
    get "/export/entries.ics", ExportController, :ical

    scope "/" do
      pipe_through :session_only

      post "/auth/logout", AuthController, :logout
      get "/auth/me", AuthController, :me
      post "/auth/totp/setup", AuthController, :totp_setup
      post "/auth/totp/confirm", AuthController, :totp_confirm
      delete "/auth/totp", AuthController, :totp_disable
      put "/auth/profile", AuthController, :update_profile
      put "/auth/password", AuthController, :change_password
      post "/auth/avatar", AuthController, :upload_avatar

      post "/entries/backfill_media", EntryController, :backfill_media

      resources "/connectors", ConnectorController, except: [:new, :edit]
      post "/connectors/:id/start", ConnectorController, :start
      post "/connectors/:id/stop", ConnectorController, :stop
      post "/connectors/:id/sync", ConnectorController, :sync
      post "/connectors/:id/import", ConnectorController, :import_file
      get "/connectors/:id/logs", ConnectorController, :logs
      get "/connectors/schedules/:connector_type", ConnectorController, :schedules

      scope "/" do
        pipe_through :admin

        get "/audit/system", AuditController, :system
        get "/audit/logs", AuditController, :logs
      end
    end
  end
end
```

**Step 5: Run tests**

Run: `mix test test/servant_web/plugs/session_only_test.exs && mix test`
Expected: PASS, full suite green (routes unchanged for sessions).

**Step 6: Commit**

```bash
mix format
git add lib/servant_web/plugs/scope.ex lib/servant_web/plugs/session_only.ex lib/servant_web/router.ex test/servant_web/plugs/session_only_test.exs
git commit -m "Scope + SessionOnly plugs; router split into token and session zones"
```

---

### Task 5: scope enforcement on Notes, uploads, meta endpoints and exports

**Files:**
- Modify: `lib/servant_web/controllers/notes_controller.ex`
- Modify: `lib/servant_web/controllers/upload_controller.ex`
- Modify: `lib/servant_web/controllers/entry_controller.ex` (meta plug only)
- Modify: `lib/servant_web/controllers/export_controller.ex`
- Test: `test/servant_web/plugs/scope_enforcement_test.exs`

**Step 1: Write the failing tests**

```elixir
defmodule ServantWeb.ScopeEnforcementTest do
  use ServantWeb.ConnCase, async: false

  describe "notes" do
    test "app:notes:read can list but not create" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:notes:read"])
      assert json_response(get(conn, ~p"/api/notes"), 200)

      conn = post(conn, ~p"/api/notes", %{"title" => "x", "body" => ""})
      assert json_response(conn, 403)["required"] == "app:notes:write"
    end

    test "app:notes:write can create" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:notes:write"])
      conn = post(conn, ~p"/api/notes", %{"title" => "from agent", "body" => "hello"})
      assert json_response(conn, 201)["data"]["title"] == "from agent"
    end

    test "a foreign-domain token gets 403 on notes" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])
      assert json_response(get(conn, ~p"/api/notes"), 403)
    end
  end

  describe "uploads" do
    test "app:photos:write can upload to photos, not to files" do
      upload = %Plug.Upload{
        path: write_tmp!("x"),
        content_type: "text/plain",
        filename: "x.txt"
      }

      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:photos:write"])
      assert json_response(post(conn, ~p"/api/uploads", %{"file" => upload, "app" => "photos"}), 200)

      {conn2, _user2} = register_and_log_in_api_token(build_conn(), ["app:photos:write"])
      conn2 = post(conn2, ~p"/api/uploads", %{"file" => upload, "app" => "files"})
      assert json_response(conn2, 403)["required"] == "app:files:write"
    end
  end

  describe "meta endpoints and exports need data:read" do
    test "kind-scoped tokens are refused" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])
      assert json_response(get(conn, ~p"/api/entries/stats"), 403)
      assert json_response(get(conn, ~p"/api/entries/kinds"), 403)
      assert response(get(conn, ~p"/api/export/entries"), 403)
    end

    test "data:read passes" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["data:read"])
      assert json_response(get(conn, ~p"/api/entries/stats"), 200)
    end
  end

  defp write_tmp!(content) do
    path = Path.join(System.tmp_dir!(), "scope-test-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    path
  end
end
```

Note: check how existing upload tests build `%Plug.Upload{}` (look at
`test/servant_web/controllers/` for an upload test) and mirror their tmp-file
and storage-dir setup if one exists.

**Step 2: Run to verify failure**

Run: `mix test test/servant_web/plugs/scope_enforcement_test.exs`
Expected: FAIL (all 200s today)

**Step 3: Implement**

`NotesController`, after `use ServantWeb, :controller`:

```elixir
plug ServantWeb.Plugs.Scope, domain: "notes"
```

`EntryController`, after `use ServantWeb, :controller`:

```elixir
plug ServantWeb.Plugs.Scope,
     [domain: "data"] when action in [:kinds, :sources, :stats, :daily_stats]
```

`ExportController`, after `use ServantWeb, :controller`:

```elixir
plug ServantWeb.Plugs.Scope, domain: "data"
```

`UploadController`, after `use ServantWeb, :controller` (a function plug, since
the domain depends on the `app` param):

```elixir
plug :check_upload_scope

# photos uploads need app:photos:write; every other app id is file storage
defp check_upload_scope(conn, _opts) do
  domain = if Map.get(conn.params, "app", "files") == "photos", do: "photos", else: "files"

  if Servant.ApiTokens.Scopes.can?(conn.assigns[:api_scopes], domain, :write) do
    conn
  else
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{
      error: "Insufficient scope",
      required: Servant.ApiTokens.Scopes.scope_name(domain, :write)
    })
    |> halt()
  end
end
```

**Step 4: Run tests**

Run: `mix test test/servant_web/plugs/scope_enforcement_test.exs && mix test`
Expected: PASS

**Step 5: Commit**

```bash
mix format
git add lib/servant_web/controllers/notes_controller.ex lib/servant_web/controllers/upload_controller.ex lib/servant_web/controllers/entry_controller.ex lib/servant_web/controllers/export_controller.ex test/servant_web/plugs/scope_enforcement_test.exs
git commit -m "Scope enforcement: notes, uploads, entry meta endpoints, exports"
```

---

### Task 6: per-kind enforcement in EntryController

**Files:**
- Modify: `lib/servant/data.ex` (new `kinds` filter)
- Modify: `lib/servant_web/controllers/entry_controller.ex`
- Test: `test/servant_web/controllers/entry_scopes_test.exs`

**Step 1: Write the failing tests**

```elixir
defmodule ServantWeb.EntryScopesTest do
  use ServantWeb.ConnCase, async: false

  defp seed(user_id) do
    entry_fixture(user_id, %{"kind" => "tracker_log", "title" => "log"})
    entry_fixture(user_id, %{"kind" => "bank_tx", "title" => "tx"})
    entry_fixture(user_id, %{"kind" => "bookmark", "title" => "bm"})
  end

  test "index is restricted to readable kinds" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:read"])
    seed(user.id)

    kinds =
      get(conn, ~p"/api/entries")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["kind"])
      |> Enum.uniq()

    assert kinds == ["tracker_log"]
  end

  test "an explicit kind filter outside the scopes is 403" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:read"])
    seed(user.id)
    conn = get(conn, ~p"/api/entries?kind=bank_tx")
    assert json_response(conn, 403)["required"] == "app:finance:read"
  end

  test "show/delete honor the entry's kind" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])
    tx = entry_fixture(user.id, %{"kind" => "bank_tx"})
    log = entry_fixture(user.id, %{"kind" => "tracker_log"})

    assert json_response(get(conn, ~p"/api/entries/#{tx.id}"), 403)
    assert json_response(get(conn, ~p"/api/entries/#{log.id}"), 200)
    assert json_response(delete(conn, ~p"/api/entries/#{tx.id}"), 403)
    assert response(delete(conn, ~p"/api/entries/#{log.id}"), 204)
  end

  test "create checks the target kind, update checks old and new kind" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])

    conn2 = post(conn, ~p"/api/entries", %{"kind" => "bank_tx", "source" => "api"})
    assert json_response(conn2, 403)["required"] == "app:finance:write"

    conn3 = post(conn, ~p"/api/entries", %{"kind" => "tracker_log", "source" => "api"})
    assert json_response(conn3, 201)

    log = entry_fixture(user.id, %{"kind" => "tracker_log"})
    conn4 = put(conn, ~p"/api/entries/#{log.id}", %{"kind" => "bank_tx"})
    assert json_response(conn4, 403)

    conn5 = put(conn, ~p"/api/entries/#{log.id}", %{"title" => "renamed"})
    assert json_response(conn5, 200)["data"]["title"] == "renamed"
  end

  test "unmapped kinds need data scopes, data:write sees everything" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["data:write"])
    seed(user.id)

    kinds =
      get(conn, ~p"/api/entries")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["kind"])
      |> Enum.uniq()
      |> Enum.sort()

    assert kinds == ["bank_tx", "bookmark", "tracker_log"]

    assert json_response(post(conn, ~p"/api/entries", %{"kind" => "bookmark", "source" => "api"}), 201)
  end

  test "sessions are unaffected" do
    {conn, user} = register_and_log_in_user(build_conn())
    seed(user.id)
    assert length(json_response(get(conn, ~p"/api/entries"), 200)["data"]) == 3
  end
end
```

**Step 2: Run to verify failure**

Run: `mix test test/servant_web/controllers/entry_scopes_test.exs`
Expected: FAIL

**Step 3: Add the `kinds` filter to Data**

In `lib/servant/data.ex` `apply_filters/2`, add a clause next to the `"kind"` one:

```elixir
{"kinds", kinds}, q when is_list(kinds) ->
  where(q, [e], e.kind in ^kinds)
```

**Step 4: Implement the controller checks**

In `lib/servant_web/controllers/entry_controller.ex` add `alias Servant.ApiTokens.Scopes` and rework the CRUD actions:

```elixir
def index(conn, params) do
  user_id = conn.assigns.current_user.id

  case restrict_params(params, conn.assigns[:api_scopes]) do
    {:ok, params} ->
      entries = Data.list_entries(user_id, params)
      total = Data.count_entries(user_id, params)

      per_page = Data.clamp_per_page(params["per_page"])
      page = max(parse_int(params["page"], 1), 1)
      total_pages = max(ceil(total / per_page), 1)

      json(conn, %{
        data: Enum.map(entries, &Entry.to_json/1),
        meta: %{page: page, per_page: per_page, total: total, total_pages: total_pages}
      })

    {:error, required} ->
      forbidden(conn, required)
  end
end

def show(conn, %{"id" => id}) do
  user_id = conn.assigns.current_user.id
  entry = Data.get_entry!(user_id, id)

  if Scopes.can_kind?(conn.assigns[:api_scopes], entry.kind, :read) do
    json(conn, %{data: Entry.to_json(entry)})
  else
    forbidden(conn, required_for(entry.kind, :read))
  end
end

def create(conn, params) do
  user_id = conn.assigns.current_user.id
  kind = params["kind"]

  if Scopes.can_kind?(conn.assigns[:api_scopes], kind, :write) do
    # existing create body unchanged
  else
    forbidden(conn, required_for(kind, :write))
  end
end

def update(conn, %{"id" => id} = params) do
  user_id = conn.assigns.current_user.id
  scopes = conn.assigns[:api_scopes]
  entry = Data.get_entry!(user_id, id)
  new_kind = Map.get(params, "kind", entry.kind)

  cond do
    not Scopes.can_kind?(scopes, entry.kind, :write) ->
      forbidden(conn, required_for(entry.kind, :write))

    not Scopes.can_kind?(scopes, new_kind, :write) ->
      forbidden(conn, required_for(new_kind, :write))

    true ->
      # existing update body unchanged (case Data.update_entry ...)
  end
end

def delete(conn, %{"id" => id}) do
  user_id = conn.assigns.current_user.id
  entry = Data.get_entry!(user_id, id)

  if Scopes.can_kind?(conn.assigns[:api_scopes], entry.kind, :write) do
    # existing delete body unchanged
  else
    forbidden(conn, required_for(entry.kind, :write))
  end
end

# Session tokens see everything. An explicit kind filter outside the token's
# scopes is a 403; without one, the query is restricted to readable kinds.
defp restrict_params(params, nil), do: {:ok, params}

defp restrict_params(%{"kind" => kind} = params, scopes) do
  if Scopes.can_kind?(scopes, kind, :read) do
    {:ok, params}
  else
    {:error, required_for(kind, :read)}
  end
end

defp restrict_params(params, scopes) do
  case Scopes.readable_kinds(scopes) do
    :all -> {:ok, params}
    kinds -> {:ok, Map.put(params, "kinds", kinds)}
  end
end

defp required_for(kind, action) do
  Scopes.scope_name(Scopes.kind_domain(kind) || "data", action)
end

defp forbidden(conn, required) do
  conn
  |> put_status(:forbidden)
  |> json(%{error: "Insufficient scope", required: required})
end
```

Keep the existing success/error bodies of create/update/delete exactly as they are; only wrap them.

Note: `delete/2` now fetches the entry before deleting (`get_entry!` raises 404 for missing ids, which changes the previous "could not delete" 422 for unknown ids into a 404; that is more correct, keep it and adjust any failing existing test's expectation only if the test asserted the old 422 for a missing id).

**Step 5: Run tests**

Run: `mix test test/servant_web/controllers/entry_scopes_test.exs && mix test`
Expected: PASS

**Step 6: Commit**

```bash
mix format
git add lib/servant/data.ex lib/servant_web/controllers/entry_controller.ex test/servant_web/controllers/entry_scopes_test.exs
git commit -m "Per-kind scope enforcement on the entries API"
```

---

### Task 7: token management endpoints

**Files:**
- Create: `lib/servant_web/controllers/api_token_controller.ex`
- Modify: `lib/servant_web/router.ex` (one line)
- Test: `test/servant_web/controllers/api_token_controller_test.exs`

**Step 1: Write the failing tests**

```elixir
defmodule ServantWeb.ApiTokenControllerTest do
  use ServantWeb.ConnCase, async: false

  test "create returns the plaintext once, list never does", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)

    created =
      conn
      |> post(~p"/api/tokens", %{"name" => "my agent", "scopes" => ["app:notes:write"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert String.starts_with?(created["token"], "srv_")
    assert created["scopes"] == ["app:notes:write"]

    listed = json_response(get(conn, ~p"/api/tokens"), 200)["data"]
    assert [%{"name" => "my agent"} = row] = listed
    refute Map.has_key?(row, "token")
    refute Map.has_key?(row, "token_hash")
  end

  test "invalid scopes are rejected", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    conn = post(conn, ~p"/api/tokens", %{"name" => "x", "scopes" => ["nope"]})
    assert json_response(conn, 422)["errors"]["scopes"]
  end

  test "delete revokes", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)

    created =
      conn
      |> post(~p"/api/tokens", %{"name" => "t", "scopes" => ["data:read"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert response(delete(conn, ~p"/api/tokens/#{created["id"]}"), 204)

    probe = build_conn() |> put_req_header("authorization", "Bearer #{created["token"]}")
    assert json_response(get(probe, ~p"/api/entries"), 401)
  end

  test "an API token cannot manage tokens (no escalation)", %{conn: conn} do
    {conn, _user} = register_and_log_in_api_token(conn, ["data:write"])
    assert json_response(get(conn, ~p"/api/tokens"), 403)

    conn = post(conn, ~p"/api/tokens", %{"name" => "evil", "scopes" => ["data:write"]})
    assert json_response(conn, 403)
  end
end
```

**Step 2: Run to verify failure**

Run: `mix test test/servant_web/controllers/api_token_controller_test.exs`
Expected: FAIL (route does not exist yet: 404s)

**Step 3: Implement**

`lib/servant_web/controllers/api_token_controller.ex`:

```elixir
defmodule ServantWeb.ApiTokenController do
  @moduledoc "Session-only management of scoped API tokens."

  use ServantWeb, :controller

  alias Servant.ApiTokens
  alias Servant.ApiTokens.ApiToken

  def index(conn, _params) do
    tokens = ApiTokens.list_tokens(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(tokens, &ApiToken.to_json/1)})
  end

  def create(conn, params) do
    case ApiTokens.create_token(conn.assigns.current_user.id, params) do
      {:ok, api_token, plaintext} ->
        conn
        |> put_status(:created)
        |> json(%{data: Map.put(ApiToken.to_json(api_token), :token, plaintext)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case ApiTokens.delete_token(conn.assigns.current_user.id, id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
```

Router: inside the `session_only` scope (next to the auth routes) add:

```elixir
resources "/tokens", ApiTokenController, only: [:index, :create, :delete]
```

**Step 4: Run tests**

Run: `mix test test/servant_web/controllers/api_token_controller_test.exs && mix test`
Expected: PASS

**Step 5: Commit**

```bash
mix format
git add lib/servant_web/controllers/api_token_controller.ex lib/servant_web/router.ex test/servant_web/controllers/api_token_controller_test.exs
git commit -m "Token management endpoints: list, create (plaintext once), revoke"
```

---

## Phase C: Settings UI

### Task 8: "API tokens" card in Settings

**Files:**
- Modify: `frontend/src/types.ts` (ApiToken interface)
- Modify: `frontend/src/views/SettingsView.vue`
- Test: `frontend/src/views/SettingsView.apitokens.test.ts` only if a SettingsView test already exists to copy patterns from; otherwise test the pure scope-building helper (see below) in `frontend/src/lib/apiTokenScopes.test.ts`
- Create: `frontend/src/lib/apiTokenScopes.ts`

The card lives inline in `SettingsView.vue` like the five existing cards (the
`.card` styles are scoped to that file). The scope-choice logic is extracted to
a small pure module so it is testable.

**Step 1: Write the pure helper + failing test**

`frontend/src/lib/apiTokenScopes.ts`:

```ts
// Mirrors Servant.ApiTokens.Scopes on the backend: app domains + data wildcard.
export interface ScopeDomain {
  id: string
  label: string
}

export const SCOPE_DOMAINS: ScopeDomain[] = [
  { id: 'notes', label: 'Notes' },
  { id: 'checklists', label: 'Checklists' },
  { id: 'calendar', label: 'Calendar' },
  { id: 'contacts', label: 'Contacts' },
  { id: 'photos', label: 'Photos' },
  { id: 'files', label: 'Files' },
  { id: 'finance', label: 'Finance' },
  { id: 'trackers', label: 'Trackers' },
  { id: 'data', label: 'All data' }
]

export type AccessLevel = 'none' | 'read' | 'write'

export function scopeFor(domain: string, level: AccessLevel): string | null {
  if (level === 'none') return null
  return domain === 'data' ? `data:${level}` : `app:${domain}:${level}`
}

// levels: domain id -> access level, from the creation form
export function buildScopes(levels: Record<string, AccessLevel>): string[] {
  return SCOPE_DOMAINS.map(d => scopeFor(d.id, levels[d.id] ?? 'none')).filter(
    (s): s is string => s !== null
  )
}
```

`frontend/src/lib/apiTokenScopes.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { buildScopes, scopeFor } from './apiTokenScopes'

describe('apiTokenScopes', () => {
  it('formats app and data scopes', () => {
    expect(scopeFor('notes', 'write')).toBe('app:notes:write')
    expect(scopeFor('data', 'read')).toBe('data:read')
    expect(scopeFor('finance', 'none')).toBeNull()
  })

  it('builds the scope list from form levels', () => {
    expect(buildScopes({ trackers: 'write', finance: 'read' })).toEqual([
      'app:finance:read',
      'app:trackers:write'
    ])
    expect(buildScopes({})).toEqual([])
  })
})
```

Run: `cd frontend && npx vitest run src/lib/apiTokenScopes.test.ts` -> FAIL, then implement, then PASS.

**Step 2: Add the ApiToken type**

In `frontend/src/types.ts`:

```ts
export interface ApiToken {
  id: string
  name: string
  prefix: string
  scopes: string[]
  expires_at: string | null
  last_used_at: string | null
  inserted_at: string
  token?: string // present only in the create response
}
```

**Step 3: Add the card to SettingsView**

In `frontend/src/views/SettingsView.vue`:

Script additions (follow the file's existing patterns: refs + async functions + `onMounted` load):

```ts
import ComboBox from '../components/ComboBox.vue' // already imported
import { TerminalSquare, Copy, Trash2 } from 'lucide-vue-next' // extend the lucide import
import type { ApiToken } from '../types'
import {
  SCOPE_DOMAINS,
  buildScopes,
  type AccessLevel
} from '../lib/apiTokenScopes'

// API tokens
const apiTokens = ref<ApiToken[]>([])
const tokenName = ref('')
const tokenExpiry = ref('') // yyyy-mm-dd from <input type="date">, optional
const tokenLevels = ref<Record<string, AccessLevel>>({})
const createdToken = ref<string | null>(null)
const tokenError = ref('')
const tokenCreating = ref(false)

const ACCESS_OPTIONS = [
  { value: 'none', label: 'No access' },
  { value: 'read', label: 'Read' },
  { value: 'write', label: 'Read + write' }
]

async function loadTokens() {
  try {
    apiTokens.value = (await api.get<{ data: ApiToken[] }>('/api/tokens')).data
  } catch {
    // section shows empty; not fatal for the rest of settings
  }
}

async function createToken() {
  tokenError.value = ''
  const scopes = buildScopes(tokenLevels.value)
  if (!tokenName.value.trim() || !scopes.length) {
    tokenError.value = 'Name and at least one scope are required'
    return
  }
  tokenCreating.value = true
  try {
    const body: Record<string, unknown> = { name: tokenName.value.trim(), scopes }
    if (tokenExpiry.value) body.expires_at = `${tokenExpiry.value}T23:59:59Z`
    const res = await api.post<{ data: ApiToken }>('/api/tokens', body)
    createdToken.value = res.data.token ?? null
    tokenName.value = ''
    tokenExpiry.value = ''
    tokenLevels.value = {}
    await loadTokens()
  } catch (e) {
    tokenError.value = e instanceof Error ? e.message : 'Creation failed'
  } finally {
    tokenCreating.value = false
  }
}

async function revokeToken(t: ApiToken) {
  if (!confirm(`Revoke "${t.name}"? Scripts using it will stop working.`)) return
  await api.del(`/api/tokens/${t.id}`)
  await loadTokens()
}

async function copyCreatedToken() {
  if (createdToken.value) await navigator.clipboard.writeText(createdToken.value)
}
```

Call `loadTokens()` inside the existing `onMounted`.

Template: a new `<section class="card">` between the 2FA card and the Export
card, following the exact same markup conventions:

```html
<section class="card">
  <div class="card-header">
    <TerminalSquare :size="20" class="card-icon" />
    <h2>API Tokens</h2>
  </div>
  <div class="card-body">
    <p class="tk-hint">
      Scoped tokens let agents and scripts use the API with limited
      permissions. Send them as "Authorization: Bearer &lt;token&gt;". Docs:
      <a href="/api/docs" target="_blank" rel="noopener">/api/docs</a>
    </p>

    <div v-if="createdToken" class="tk-created">
      <p class="tk-created-warning">
        Copy this token now: it will not be shown again.
      </p>
      <code class="tk-created-value">{{ createdToken }}</code>
      <div class="card-actions">
        <button type="button" @click="copyCreatedToken"><Copy :size="14" /> Copy</button>
        <button type="button" @click="createdToken = null">Done</button>
      </div>
    </div>

    <table v-if="apiTokens.length" class="tk-table">
      <thead>
        <tr>
          <th>Name</th><th>Scopes</th><th>Last used</th><th>Expires</th><th></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="t in apiTokens" :key="t.id">
          <td>{{ t.name }} <span class="tk-prefix">{{ t.prefix }}…</span></td>
          <td><span v-for="s in t.scopes" :key="s" class="tk-scope">{{ s }}</span></td>
          <td>{{ t.last_used_at ? formatDate(t.last_used_at) : 'never' }}</td>
          <td>{{ t.expires_at ? formatDate(t.expires_at) : '-' }}</td>
          <td>
            <button type="button" class="tk-revoke" title="Revoke" @click="revokeToken(t)">
              <Trash2 :size="14" />
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-else class="tk-empty">No API tokens yet.</p>

    <form class="tk-form" @submit.prevent="createToken">
      <input v-model="tokenName" type="text" placeholder="Token name (e.g. tracker bot)" />
      <div class="tk-domains">
        <div v-for="d in SCOPE_DOMAINS" :key="d.id" class="tk-domain">
          <span class="tk-domain-label">{{ d.label }}</span>
          <ComboBox
            :model-value="tokenLevels[d.id] ?? 'none'"
            :options="ACCESS_OPTIONS"
            @update:model-value="v => (tokenLevels[d.id] = v as AccessLevel)"
          />
        </div>
      </div>
      <label class="tk-expiry">
        Expires (optional)
        <input v-model="tokenExpiry" type="date" />
      </label>
      <p v-if="tokenError" class="error">{{ tokenError }}</p>
      <div class="card-actions">
        <button type="submit" :disabled="tokenCreating">Create token</button>
      </div>
    </form>
  </div>
</section>
```

Check the `ComboBox` props contract in
`frontend/src/components/ComboBox.vue` before wiring (options accept
`{value, label}` objects) and reuse the existing error/`card-actions` styles.
Add scoped styles for the `tk-*` classes matching the file's visual language
(mono muted `tk-prefix`, violet-tinted `tk-scope` chips like `.nt-tag`, danger
hover on `tk-revoke`; `tk-domains` is a two-column grid, `gap: 0.5rem`).
Native `<input type="date">` is fine here (platform feature over a picker lib).

**Step 4: Verify**

```bash
cd frontend && npx vue-tsc --noEmit -p tsconfig.app.json && npx vitest run && npm run format
```
Expected: typecheck clean, tests pass.

Manual check (optional but recommended): `mix phx.server` + `npm run dev`, create a token in Settings, then:

```bash
curl -H "Authorization: Bearer srv_..." http://localhost:4001/api/entries
```

**Step 5: Commit**

```bash
git add frontend/src/types.ts frontend/src/lib/apiTokenScopes.ts frontend/src/lib/apiTokenScopes.test.ts frontend/src/views/SettingsView.vue
git commit -m "Settings: API tokens card (create with scopes, list, revoke)"
```

---

## Phase D: OpenAPI

### Task 9: open_api_spex wiring (spec module, routes, smoke test)

**Files:**
- Modify: `mix.exs`
- Create: `lib/servant_web/api_spec.ex`
- Modify: `lib/servant_web/router.ex`
- Test: `test/servant_web/openapi_test.exs` (smoke part)

**Step 1: Add the dependency**

In `mix.exs` deps: `{:open_api_spex, "~> 3.22"},` then `mix deps.get`.

**Step 2: Write the failing smoke test**

```elixir
defmodule ServantWeb.OpenApiTest do
  use ServantWeb.ConnCase, async: true

  test "serves a valid JSON spec without auth", %{conn: conn} do
    spec = json_response(get(conn, "/api/openapi.json"), 200)
    assert spec["openapi"] =~ "3."
    assert spec["info"]["title"] == "Servant API"
    assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
  end

  test "serves SwaggerUI", %{conn: conn} do
    conn = get(conn, "/api/docs")
    assert response(conn, 200) =~ "swagger"
  end
end
```

**Step 3: Implement the spec module**

`lib/servant_web/api_spec.ex`:

```elixir
defmodule ServantWeb.ApiSpec do
  @moduledoc "OpenAPI specification, served at /api/openapi.json (SwaggerUI at /api/docs)."

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Servant API",
        description: """
        Self-hosted personal data hub.

        Authentication: `Authorization: Bearer <token>`. Two credential types:
        - session tokens (used by the SPA, also carried by an HttpOnly cookie): full access
        - API tokens (`srv_` prefixed, created in Settings): restricted by scopes of the
          form `app:<domain>:<read|write>` (notes, checklists, calendar, contacts, photos,
          files, finance, trackers) plus the `data:<read|write>` wildcard. `write` implies
          `read`. Scope failures return 403 with the required scope.
        """,
        version: to_string(Application.spec(:servant, :vsn) || "dev")
      },
      servers: [Server.from_endpoint(ServantWeb.Endpoint)],
      paths: Paths.from_router(ServantWeb.Router),
      components: %Components{
        securitySchemes: %{"bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
```

**Step 4: Serve it from the router**

Add the pipeline and scope (before the main `/api` scope; no auth: the spec
describes shapes, not data):

```elixir
pipeline :openapi do
  plug OpenApiSpex.Plug.PutApiSpec, module: ServantWeb.ApiSpec
end

scope "/api" do
  pipe_through :openapi

  get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
end
```

Note: `Paths.from_router/1` logs warnings for controller actions without an
`open_api_operation`; they are expected until Tasks 10-11 finish.

**Step 5: Run**

Run: `mix test test/servant_web/openapi_test.exs`
Expected: PASS (spec has empty-ish paths for now, that is fine)

**Step 6: Commit**

```bash
mix format
git add mix.exs mix.lock lib/servant_web/api_spec.ex lib/servant_web/router.ex test/servant_web/openapi_test.exs
git commit -m "OpenAPI skeleton: open_api_spex, /api/openapi.json, SwaggerUI at /api/docs"
```

---

### Task 10: shared schema modules

**Files (one module per file, per AGENTS.md):**
- Create: `lib/servant_web/schemas/entry.ex`
- Create: `lib/servant_web/schemas/api_token.ex`
- Create: `lib/servant_web/schemas/pagination_meta.ex`
- Create: `lib/servant_web/schemas/error.ex`

No dedicated test (Task 12's anti-drift + validity test covers them).

`lib/servant_web/schemas/entry.ex` (mirror `Servant.Data.Entry.to_json/1` exactly):

```elixir
defmodule ServantWeb.Schemas.Entry do
  @moduledoc false

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Entry",
    description: "Universal user-scoped data container. Notes are entries too but are written through /api/notes.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      kind: %Schema{type: :string, example: "tracker_log"},
      source: %Schema{type: :string, example: "api"},
      external_id: %Schema{type: :string, nullable: true},
      title: %Schema{type: :string, nullable: true},
      occurred_at: %Schema{type: :string, format: :"date-time", nullable: true},
      data: %Schema{type: :object, additionalProperties: true},
      metadata: %Schema{type: :object, additionalProperties: true, nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :kind]
  })
end
```

`api_token.ex`: object with `id`, `name`, `prefix`, `scopes` (array of string,
example `["app:trackers:write"]`), `expires_at`/`last_used_at`/`inserted_at`
(date-time, nullable where applicable), plus optional `token` (string,
description "full plaintext, present only in the create response").

`pagination_meta.ex`: object with integer `page`, `per_page`, `total`,
`total_pages`.

`error.ex`: object with `error` (string) and optional `required` (string,
description "missing scope, on 403"), plus optional `errors` (object) for
changeset maps.

Run: `mix compile --warnings-as-errors` -> clean. Commit:

```bash
mix format
git add lib/servant_web/schemas/
git commit -m "OpenAPI schemas: Entry, ApiToken, PaginationMeta, Error"
```

---

### Task 11: annotate every controller

**Files:**
- Modify: all files in `lib/servant_web/controllers/` except `error_json.ex`, `spa_controller.ex`, `files_controller.ex` (not under /api)

For each controller add, after `use ServantWeb, :controller`:

```elixir
use OpenApiSpex.ControllerSpecs

tags ["<domain>"]
```

and one `operation :action, ...` block per action, placed immediately above
each action. Rules:

- `summary:` always; `description:` mentions required scopes where relevant
  (e.g. "Requires app:notes:write for an API token").
- Path params typed (`id: [in: :path, type: :string, required: true]`).
- Responses reference the schema modules or inline `%OpenApiSpex.Schema{}`
  wrappers; the standard error responses are
  `unauthorized: {"Unauthorized", "application/json", ServantWeb.Schemas.Error}` and
  `forbidden: {"Insufficient scope", "application/json", ServantWeb.Schemas.Error}`.

Precision matters most on the token-reachable surface; session-only endpoints
(auth, connectors, audit) may use loose `%Schema{type: :object}` response
bodies. Full example for the entries controller (apply the same pattern
everywhere):

```elixir
use OpenApiSpex.ControllerSpecs

alias OpenApiSpex.Schema
alias ServantWeb.Schemas

tags ["entries"]

@entry_page %Schema{
  type: :object,
  properties: %{
    data: %Schema{type: :array, items: Schemas.Entry},
    meta: Schemas.PaginationMeta
  }
}
@entry_envelope %Schema{type: :object, properties: %{data: Schemas.Entry}}

operation :index,
  summary: "List entries",
  description:
    "Filterable, paginated. API tokens only see kinds their scopes can read; an explicit kind filter outside the scopes returns 403.",
  parameters: [
    kind: [in: :query, type: :string, required: false],
    source: [in: :query, type: :string, required: false],
    q: [in: :query, type: :string, required: false, description: "substring search"],
    from: [in: :query, type: :string, required: false, description: "ISO8601 lower bound on occurred_at"],
    to: [in: :query, type: :string, required: false],
    sort: [in: :query, type: :string, required: false, description: "inserted_at for newest-first by creation"],
    page: [in: :query, type: :integer, required: false],
    per_page: [in: :query, type: :integer, required: false]
  ],
  responses: [
    ok: {"Entries page", "application/json", @entry_page},
    unauthorized: {"Unauthorized", "application/json", Schemas.Error},
    forbidden: {"Insufficient scope", "application/json", Schemas.Error}
  ]

operation :show,
  summary: "Get one entry",
  parameters: [id: [in: :path, type: :string, required: true]],
  responses: [
    ok: {"Entry", "application/json", @entry_envelope},
    forbidden: {"Insufficient scope", "application/json", Schemas.Error},
    not_found: {"Not found", "application/json", Schemas.Error}
  ]

operation :create,
  summary: "Create an entry",
  description: "Requires write scope on the kind's domain. Notes cannot be created here (use /api/notes).",
  request_body: {"Entry attributes", "application/json", %Schema{
    type: :object,
    properties: %{
      kind: %Schema{type: :string},
      source: %Schema{type: :string},
      title: %Schema{type: :string},
      occurred_at: %Schema{type: :string, format: :"date-time"},
      data: %Schema{type: :object, additionalProperties: true}
    },
    required: [:kind, :source]
  }},
  responses: [
    created: {"Entry", "application/json", @entry_envelope},
    forbidden: {"Insufficient scope", "application/json", Schemas.Error},
    unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
  ]
```

...and so on for `update`, `delete`, `kinds`, `sources`, `stats`,
`daily_stats`, `backfill_media`.

Controller-by-controller checklist (every action must get an operation):

| Controller | tags | Actions |
|---|---|---|
| AuthController | auth | config, register, login, totp_verify, logout, me, totp_setup, totp_confirm, totp_disable, update_profile, change_password, upload_avatar |
| EntryController | entries | index, show, create, update, delete, kinds, sources, stats, daily_stats, backfill_media |
| NotesController | notes | index, show, create, update, delete, backlinks, mentioning |
| ApiTokenController | tokens | index, create, delete |
| ConnectorController | connectors | index, show, create, update, delete, start, stop, sync, import_file, logs, schedules |
| AppController | apps | index |
| UploadController | uploads | create (multipart: document `file` + `app` form fields) |
| ExportController | export | entries, ical |
| AuditController | audit | system, logs |

Verify progressively with `mix compile --warnings-as-errors` and by checking
`Paths.from_router` warnings disappear:
`mix run -e 'ServantWeb.ApiSpec.spec()' 2>&1 | grep -i warn` (expect no output when done).

Commit in two steps if convenient (token-reachable controllers, then session-only ones):

```bash
mix format
git add lib/servant_web/controllers/
git commit -m "OpenAPI operations on all API controllers"
```

---

### Task 12: anti-drift test

**Files:**
- Modify: `test/servant_web/openapi_test.exs`

**Step 1: Add the failing test**

```elixir
@verbs ~w(get put post delete options head patch trace)a

test "every /api route is documented in the spec" do
  spec = ServantWeb.ApiSpec.spec()

  documented =
    for {path, item} <- spec.paths,
        verb <- @verbs,
        not is_nil(Map.get(item, verb)),
        into: MapSet.new(),
        do: {verb, path}

  expected =
    for r <- ServantWeb.Router.__routes__(),
        String.starts_with?(r.path, "/api"),
        r.path not in ["/api/openapi.json", "/api/docs"],
        into: MapSet.new(),
        do: {r.verb, to_openapi_path(r.path)}

  assert MapSet.to_list(MapSet.difference(expected, documented)) == []
end

test "the spec serializes to JSON" do
  assert {:ok, _json} = Jason.encode(OpenApiSpex.OpenApi.to_map(ServantWeb.ApiSpec.spec()))
end

defp to_openapi_path(path) do
  path
  |> String.split("/")
  |> Enum.map_join("/", fn
    ":" <> name -> "{#{name}}"
    "*" <> name -> "{#{name}}"
    seg -> seg
  end)
end
```

**Step 2: Run**

Run: `mix test test/servant_web/openapi_test.exs`
Expected: PASS if Task 11 is complete; otherwise the failure lists exactly the
missing `{verb, path}` pairs: finish annotating those.

**Step 3: Commit**

```bash
mix format
git add test/servant_web/openapi_test.exs
git commit -m "OpenAPI anti-drift test: every /api route must be documented"
```

---

### Task 13: final pass

**Step 1: Full verification**

```bash
mix precommit
cd frontend && npx vue-tsc --noEmit -p tsconfig.app.json && npx vitest run && npm run format && npm run build
```
Expected: everything green. Fix anything that is not.

**Step 2: Documentation touch-ups**

- `DEVELOPMENT.md`: add two lines in "Architecture notes": API tokens
  (scoped, hashed, Settings-managed) and OpenAPI docs at `/api/docs`.
- `README.md`: mention `/api/docs` and the scoped-token model in the API
  section if one exists (check first; keep it to a couple of lines).

**Step 3: Commit**

```bash
git add DEVELOPMENT.md README.md
git commit -m "Docs: scoped API tokens and OpenAPI endpoints"
```

**Step 4: Deployment note (tell the user, do not do it)**

Production needs `mix ecto.migrate` (new `api_tokens` table). No env vars, no
config changes.
