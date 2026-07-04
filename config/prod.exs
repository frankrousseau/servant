import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :servant, ServantWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Docker image build needs secret_key_base at compile time (encrypted Ecto field defaults).
# runtime.exs replaces this with the real SECRET_KEY_BASE when the release starts.
if key = System.get_env("SECRET_KEY_BASE") do
  config :servant, ServantWeb.Endpoint, secret_key_base: key
end

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
