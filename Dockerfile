# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 — build the Vue SPA into priv/static
###############################################################################
FROM node:22-bookworm-slim AS frontend

WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

# vite.config.ts writes the build to ../priv/static (also copies frontend/public/)
COPY frontend/ ./
RUN mkdir -p /app/priv/static
RUN npm run build

###############################################################################
# Stage 2 — build the Elixir release
###############################################################################
FROM hexpm/elixir:1.20.2-erlang-29.0.3-debian-bookworm-20260623-slim AS build

# Build tools for the exqlite NIF (SQLite is compiled in, no system sqlite needed)
RUN apt-get update -y \
    && apt-get install -y build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Compile-time placeholder — runtime.exs replaces this when the container starts.
ENV SECRET_KEY_BASE=build-time-placeholder-for-mix-compile-only-replaced-at-container-start-64

# Dependencies first for better layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Application source
COPY config config
COPY priv priv
COPY lib lib

# SPA produced by the frontend stage (already in priv/static, digest it here)
COPY --from=frontend /app/priv/static ./priv/static

RUN mix compile
RUN mix phx.digest
RUN mix release

###############################################################################
# Stage 3 — minimal runtime
###############################################################################
FROM debian:bookworm-slim AS app

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Database lives on a mounted volume
RUN mkdir -p /data/files /data/tmp && chown -R nobody:nogroup /data
ENV DATABASE_PATH=/data/servant.db
ENV FILES_DIR=/data/files
ENV TMP_DIR=/data/tmp

COPY --from=build --chown=nobody:nogroup /app/_build/prod/rel/servant ./
COPY --chown=nobody:nogroup docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Invoice Collector: its Playwright scraper runs via node at sync time.
# Node 22 + scraper deps + Chromium add roughly 1 GB to the image; delete
# this block (and the ENV line) if you do not use that connector.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN apt-get update -y && apt-get install -y curl \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && mkdir -p /opt/playwright \
    && cd /app/lib/servant-*/priv/scrapers \
    && npm ci --omit=dev \
    && npx playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.npm \
    && chmod -R a+rX /opt/playwright

USER nobody

ENV PHX_SERVER=true
ENV PORT=4000
EXPOSE 4000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["bin/servant", "start"]
