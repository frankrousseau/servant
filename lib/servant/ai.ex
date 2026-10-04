defmodule Servant.AI do
  @moduledoc """
  Minimal client for chat completion endpoints that are compatible with OpenAI
  (Ollama, LM Studio, vLLM, Mistral, OpenAI, the compatibility layer of
  Anthropic). There is one protocol and no adapter for each vendor. The user
  configures a base URL, a model and an optional API key in Settings > Agents.

  There is no SSRF guard on the base URL. A base URL that points at localhost
  (a local Ollama) is the usual case. The user sets the URL deliberately.
  """

  # Local models on CPU can take minutes to generate a full app module.
  @receive_timeout 300_000

  @doc """
  Sends `messages` to `{base_url}/chat/completions`. Returns
  `{:ok, %{content: binary, usage: usage}}` or `{:error, message}`. `usage` is
  `%{input_tokens: n, output_tokens: n}`, or nil when the server does not
  report it. `opts` are extra Req options. The tests inject `plug:` stubs
  through them.
  """
  def chat(config, messages, opts \\ []) do
    url = String.trim_trailing(to_string(config["base_url"]), "/") <> "/chat/completions"

    request =
      [
        url: url,
        json: %{model: config["model"], messages: messages, stream: false},
        headers: auth_headers(config["api_key"]),
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ opts

    case Req.post(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{excerpt(body)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp auth_headers(key) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer #{key}"}]

  defp auth_headers(_), do: []

  defp parse(%{"choices" => [%{"message" => %{"content" => content}} | _]} = body)
       when is_binary(content) do
    {:ok, %{content: content, usage: usage(body["usage"])}}
  end

  defp parse(body), do: {:error, "unexpected response: #{excerpt(body)}"}

  defp usage(%{"prompt_tokens" => input, "completion_tokens" => output})
       when is_integer(input) and is_integer(output) do
    %{input_tokens: input, output_tokens: output}
  end

  defp usage(_), do: nil

  defp excerpt(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp excerpt(body), do: body |> inspect() |> String.slice(0, 300)
end
