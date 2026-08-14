# NettedX Automatic Window Operator

This operator removes the need to manually freeze and settle every window.

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

Deploy the contracts with `script/Deploy.s.sol`, then set the Netting address and the private key of the Netting owner:

```powershell
$env:RPC_URL = "http://127.0.0.1:8545"
$env:NETTING_ADDRESS = "0xYourNettingAddress"
$env:PRIVATE_KEY = "0xYourOwnerPrivateKey"

.\keeper\auto-window.ps1
```

Keep the operator process running. It polls the read-only `automationState()` function and only sends a transaction when freezing or settlement is due.

Use only test keys on Anvil. Never commit a private key or reuse the public Anvil test keys on a production network.
