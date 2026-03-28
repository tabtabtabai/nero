FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gh \
        git \
        imagemagick \
        jq \
        libxml2-utils \
        p7zip-full \
        pandoc \
        poppler-utils \
        procps \
        python3 \
        python3-openpyxl \
        python3-pip \
        tesseract-ocr \
        tesseract-ocr-eng \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages 'xlrd==1.2.0'

RUN npm install -g opencode-ai@latest

COPY entrypoint.sh /usr/local/bin/nero-entrypoint
RUN chmod +x /usr/local/bin/nero-entrypoint

USER node
WORKDIR /workspace/agents

EXPOSE 4096

ENTRYPOINT ["/usr/local/bin/nero-entrypoint"]
