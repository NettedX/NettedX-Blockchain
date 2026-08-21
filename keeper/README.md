# NettedX Automatic Window Operator

This Python operator removes the need to manually freeze and settle every window. It listens for new blocks through WebSocket and signs transactions locally with the Netting owner key.

## Timeline

- Blocks 1-10: window N accepts trades.
- Block 11: window N freezes and window N+1 starts accepting trades.
- Blocks 12-13: participants prepare funds while window N+1 continues trading.
- Block 14: window N settles while window N+1 continues trading.

New trading windows start every 10 blocks. Each window still settles on its own 14th block.

## Run

Start Anvil with interval mining so blocks continue even when no user sends a transaction:

```powershell
anvil --block-time 2 --chain-id 31337
```

Create a Python environment and install the keeper dependency:

```powershell
python -m venv .\keeper\.venv
.\keeper\.venv\Scripts\Activate.ps1
pip install -r .\keeper\requirements.txt
```

Deploy the contracts with `script/Deploy.s.sol`, then set the WebSocket RPC URL, Netting address and Netting owner private key:

```powershell
$env:WS_RPC_URL = "ws://127.0.0.1:8545"
$env:NETTING_ADDRESS = "0xYourNettingAddress"
$env:PRIVATE_KEY = "0xYourOwnerPrivateKey"

python .\keeper\auto_window.py
```

Keep the operator process running. It subscribes to `newHeads`, reads `automationState()` after every new block, and only sends a signed transaction when freezing or settlement is due. On startup and after reconnecting, it checks the current state immediately so short disconnections do not skip due actions.

Optional environment variables:

- `RECONNECT_DELAY_SECONDS` (default `3`)
- `RECEIPT_TIMEOUT_SECONDS` (default `30`)
- `MAX_CATCH_UP_ACTIONS` (default `20`)

Use only test keys on Anvil. Never commit a private key or reuse the public Anvil test keys on a production network.
