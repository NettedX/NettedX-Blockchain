#!/bin/sh
set -e

DEPLOY_FILE="broadcast/Deploy.s.sol/31337/run-latest.json"
OUTPUT_FILE="frontend/src/contracts/addresses.ts"

if [ ! -f "$DEPLOY_FILE" ]; then
  echo "❌ Deployment file not found: $DEPLOY_FILE"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

python3 - "$DEPLOY_FILE" "$OUTPUT_FILE" <<'PY'
import json
import sys

deploy_file = sys.argv[1]
output_file = sys.argv[2]

with open(deploy_file) as f:
    data = json.load(f)

contracts = {}

for tx in data.get("transactions", []):
    contract_name = tx.get("contractName")
    contract_address = tx.get("contractAddress")

    if contract_name and contract_address:
        contracts[contract_name] = contract_address

wanted = [
    "MockUSDC",
    "MockBond",
    "Settlement",
    "Netting",
    "LiquidityPool",
]

lines = [
    "// AUTO-GENERATED FILE - DO NOT EDIT",
    "",
    "export const CONTRACT_ADDRESSES = {",
]

for name in wanted:
    address = contracts.get(name)

    if not address:
        print(f"❌ Missing contract: {name}")
        sys.exit(1)

    lines.append(f'  {name}: "{address}",')

lines += [
    "} as const;",
    "",
]

with open(output_file, "w") as f:
    f.write("\n".join(lines))

print(f"✅ Generated {output_file}")
PY

cat "$OUTPUT_FILE"



