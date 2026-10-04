# The tests go through failure paths that write logs on purpose: retries,
# auth challenges, connector crashes. Capture the logs. Print them only for
# a test that fails.
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Servant.Repo, :manual)
