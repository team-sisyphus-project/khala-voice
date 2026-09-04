# Hestia preflight(dockerfile.base-image-pinned): FROM은 변수 없이 핀 고정.
FROM node:22.18.0-bookworm-slim AS web-builder

WORKDIR /workspace/apps/web
COPY apps/web/package.json apps/web/package-lock.json ./
RUN npm ci

COPY apps/web ./
COPY packages/core /workspace/packages/core
COPY packages/ui-styles /workspace/packages/ui-styles
RUN npm run build

FROM hexpm/elixir:1.19.5-erlang-28.1.1-debian-bookworm-20260824-slim AS app-builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY backend/mix.exs backend/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY backend/config/config.exs backend/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY backend/priv priv
COPY --from=web-builder /workspace/backend/priv/static/app priv/static/app
COPY backend/lib lib
COPY backend/assets assets
# assets/css가 ../../../packages/ui-styles를 참조 — /app 기준이라 /packages에 복사.
COPY packages/ui-styles /packages/ui-styles

RUN mix compile
RUN mix assets.deploy

COPY backend/config/runtime.exs config/
RUN mix release

FROM debian:bookworm-20260824-slim

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses5 locales ca-certificates ffmpeg \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV MIX_ENV="prod" PHX_SERVER="true"

WORKDIR /app
RUN chown nobody /app

COPY --from=app-builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/vr ./

USER nobody

RUN ffmpeg -version > /dev/null && ffprobe -version > /dev/null

CMD ["/app/bin/vr", "start"]
