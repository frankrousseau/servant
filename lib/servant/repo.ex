defmodule Servant.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :servant,
    adapter: Ecto.Adapters.SQLite3
end
