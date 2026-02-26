FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl wget git \
    python3 python3-pip \
    jq ripgrep fd-find \
    build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 agent
USER agent
WORKDIR /workspace
CMD ["sleep", "infinity"]
