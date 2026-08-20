FROM ghcr.io/foundry-rs/foundry:v1.7.1

WORKDIR /app

COPY . .

RUN git config --global --add safe.directory /app

RUN forge build
RUN forge test