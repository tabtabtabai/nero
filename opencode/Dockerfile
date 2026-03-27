FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        openssh-client \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai@latest

RUN useradd --create-home --shell /bin/bash opencode

COPY entrypoint.sh /usr/local/bin/nero-entrypoint
RUN chmod +x /usr/local/bin/nero-entrypoint

USER opencode
WORKDIR /workspace/agent

EXPOSE 4096

ENTRYPOINT ["/usr/local/bin/nero-entrypoint"]
