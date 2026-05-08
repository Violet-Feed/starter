FROM python:3.11-slim AS build
WORKDIR /app
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock* ./
RUN uv sync --frozen --no-dev

FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/.venv .venv
COPY . .
ENV PATH="/app/.venv/bin:$PATH"
RUN bash install_librocketmq.sh
RUN bash gen_proto.sh

ENTRYPOINT ["uv", "run", "python", "main.py"]