FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pixi
RUN curl -fsSL https://pixi.sh/install.sh | bash

ENV PATH="/root/.pixi/bin:$PATH"

# Set Modular conda channels as global pixi defaults
RUN mkdir -p /root/.pixi && printf \
    'default-channels = ["https://conda.modular.com/max", "conda-forge"]\n' \
    > /root/.pixi/config.toml

WORKDIR /app

CMD ["bash"]
