defmodule Servant.Connectors.EVM.ENS do
  @moduledoc """
  Resolves ENS `.eth` names to wallet addresses.
  """

  # ponytail: resolves through the public ensideas API (one GET, no keccak256 /
  # eth_call plumbing). Change to on-chain resolution if that API goes away.
  def resolve(name) do
    url = "https://api.ensideas.com/ens/resolve/#{URI.encode(name)}"

    case Req.get(url, Servant.HTTP.req_options()) do
      {:ok, %Req.Response{status: 200, body: %{"address" => "0x" <> _ = address}}} ->
        {:ok, address}

      {:ok, %Req.Response{status: 200, body: %{"address" => nil}}} ->
        {:error, :ens_name_not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
