# Tests exercise failure paths (retries, auth challenges, connector crashes)
# that log on purpose: capture the logs and print them only for a failing test.
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Servant.Repo, :manual)
