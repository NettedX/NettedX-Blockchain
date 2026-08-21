FROM ghcr.io/foundry-rs/foundry:v1.7.1

WORKDIR /app

COPY --chown=foundry:foundry . .

RUN git config --global --add safe.directory /app

# For data directory
RUN mkdir -p /app/address-data

RUN forge build

RUN forge test