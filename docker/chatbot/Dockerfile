FROM python:3.11-slim AS build

WORKDIR /app

ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
ENV PATH="/app/.venv/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

RUN apt-get update && apt-get install -y --no-install-recommends \
    protobuf-compiler \
    bash \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml uv.lock* ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

COPY . .

RUN bash gen_proto.sh


FROM python:3.11-slim

WORKDIR /app

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app /app

RUN bash install_librocketmq.sh

ENTRYPOINT ["chatbot-bot"]