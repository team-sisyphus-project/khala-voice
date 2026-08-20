# ══════════════════════════════════════════════════════════════
#  Voice Recording — 프로덕션 이미지
#
#  FFmpeg이 반드시 포함되어야 한다. 없으면 20분 초과 녹음의 분할과
#  STT 전달 전 MP3 변환이 전부 실패한다.
# ══════════════════════════════════════════════════════════════

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.1
ARG DEBIAN_VERSION=bookworm-20250630-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ── 빌드 ──────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ── 런타임 ────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses5 locales ca-certificates \
       ffmpeg \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# UTF-8 로케일. 없으면 한국어 로그가 \x{...} 로 깨져 나온다.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/vr ./

USER nobody

# FFmpeg 존재 확인 — 빌드 시점에 깨진 이미지를 잡는다
RUN ffmpeg -version > /dev/null && ffprobe -version > /dev/null

CMD ["/app/bin/server"]
