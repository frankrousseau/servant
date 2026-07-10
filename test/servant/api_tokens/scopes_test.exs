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

  describe "can_read_binary?/1" do
    test "sessions can, tokens need the explicit scope" do
      assert Scopes.can_read_binary?(nil) == true
      assert Scopes.can_read_binary?(["data:read-binary"]) == true
      assert Scopes.can_read_binary?(["data:write", "app:photos:read"]) == false
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
