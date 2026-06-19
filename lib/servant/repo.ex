defmodule Servant.Repo do
  use Ecto.Repo,
    otp_app: :servant,
    adapter: Ecto.Adapters.SQLite3
end
