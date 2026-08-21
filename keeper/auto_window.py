import asyncio
import logging
import os
import sys
from dataclasses import dataclass
from typing import Any

from eth_account import Account
from web3 import AsyncWeb3, Web3, WebSocketProvider


NETTING_ABI = [
    {
        "inputs": [],
        "name": "automationState",
        "outputs": [
            {"internalType": "bool", "name": "freezeNeeded", "type": "bool"},
            {"internalType": "bool", "name": "settlementNeeded", "type": "bool"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "freezeWindow",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "executeWindow",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "owner",
        "outputs": [{"internalType": "address", "name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]

LOGGER = logging.getLogger("nettedx-keeper")


class ConfigurationError(ValueError):
    pass


@dataclass(frozen=True)
class Settings:
    ws_rpc_url: str
    netting_address: str
    private_key: str
    reconnect_delay_seconds: float
    receipt_timeout_seconds: float
    max_catch_up_actions: int

    @classmethod
    def from_environment(cls) -> "Settings":
        ws_rpc_url = os.getenv("WS_RPC_URL", "ws://127.0.0.1:8545").strip()
        netting_address = os.getenv("NETTING_ADDRESS", "").strip()
        private_key = os.getenv("PRIVATE_KEY", "").strip()

        if not ws_rpc_url.startswith(("ws://", "wss://")):
            raise ConfigurationError("WS_RPC_URL must start with ws:// or wss://")
        if not Web3.is_address(netting_address):
            raise ConfigurationError("NETTING_ADDRESS is missing or invalid")
        if not private_key:
            raise ConfigurationError("PRIVATE_KEY is missing")

        try:
            Account.from_key(private_key)
        except Exception as exc:
            raise ConfigurationError("PRIVATE_KEY is invalid") from exc

        return cls(
            ws_rpc_url=ws_rpc_url,
            netting_address=Web3.to_checksum_address(netting_address),
            private_key=private_key,
            reconnect_delay_seconds=_positive_float("RECONNECT_DELAY_SECONDS", 3.0),
            receipt_timeout_seconds=_positive_float("RECEIPT_TIMEOUT_SECONDS", 30.0),
            max_catch_up_actions=_positive_int("MAX_CATCH_UP_ACTIONS", 20),
        )


def _positive_float(name: str, default: float) -> float:
    try:
        value = float(os.getenv(name, str(default)))
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be a number") from exc

    if value <= 0:
        raise ConfigurationError(f"{name} must be greater than zero")
    return value


def _positive_int(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be an integer") from exc

    if value <= 0:
        raise ConfigurationError(f"{name} must be greater than zero")
    return value


async def send_transaction(
    w3: AsyncWeb3,
    contract_function: Any,
    account: Any,
    action_name: str,
    receipt_timeout_seconds: float,
) -> None:
    transaction_base = {"from": account.address}
    estimated_gas = await contract_function.estimate_gas(transaction_base)
    transaction = await contract_function.build_transaction(
        {
            "from": account.address,
            "nonce": await w3.eth.get_transaction_count(account.address, "pending"),
            "chainId": await w3.eth.chain_id,
            "gas": estimated_gas * 120 // 100,
            "gasPrice": await w3.eth.gas_price,
        }
    )
    signed_transaction = account.sign_transaction(transaction)
    transaction_hash = await w3.eth.send_raw_transaction(signed_transaction.raw_transaction)
    receipt = await w3.eth.wait_for_transaction_receipt(
        transaction_hash,
        timeout=receipt_timeout_seconds,
    )

    if receipt["status"] != 1:
        raise RuntimeError(f"{action_name} transaction reverted: {transaction_hash.hex()}")

    LOGGER.info(
        "%s confirmed in block %s: %s",
        action_name,
        receipt["blockNumber"],
        transaction_hash.hex(),
    )


async def process_due_actions(
    w3: AsyncWeb3,
    contract: Any,
    account: Any,
    settings: Settings,
) -> None:
    for _ in range(settings.max_catch_up_actions):
        freeze_needed, settlement_needed = await contract.functions.automationState().call()

        if freeze_needed:
            await send_transaction(
                w3,
                contract.functions.freezeWindow(),
                account,
                "freezeWindow",
                settings.receipt_timeout_seconds,
            )
            continue

        if settlement_needed:
            await send_transaction(
                w3,
                contract.functions.executeWindow(),
                account,
                "executeWindow",
                settings.receipt_timeout_seconds,
            )
            continue

        return

    LOGGER.warning(
        "Reached MAX_CATCH_UP_ACTIONS=%s; remaining work will retry on the next block",
        settings.max_catch_up_actions,
    )


async def run_connection(settings: Settings) -> None:
    account = Account.from_key(settings.private_key)

    async with AsyncWeb3(WebSocketProvider(settings.ws_rpc_url)) as w3:
        if not await w3.is_connected():
            raise ConnectionError("WebSocket RPC connection failed")

        contract = w3.eth.contract(address=settings.netting_address, abi=NETTING_ABI)
        owner = await contract.functions.owner().call()

        if owner.lower() != account.address.lower():
            raise ConfigurationError(
                f"Configured signer {account.address} is not the Netting owner {owner}"
            )

        subscription_id = await w3.eth.subscribe("newHeads")
        latest_block = await w3.eth.block_number

        LOGGER.info(
            "Connected; signer=%s netting=%s latestBlock=%s subscription=%s",
            account.address,
            settings.netting_address,
            latest_block,
            subscription_id,
        )

        # Catch up immediately in case actions became due while disconnected.
        await process_due_actions(w3, contract, account, settings)

        async for subscription_message in w3.socket.process_subscriptions():
            block_header = subscription_message.get("result", subscription_message)
            block_number = block_header.get("number")

            if block_number is None:
                LOGGER.warning("Ignored subscription message without a block number")
                continue

            LOGGER.info("New block: %s", block_number)
            await process_due_actions(w3, contract, account, settings)


async def run_keeper(settings: Settings) -> None:
    while True:
        try:
            await run_connection(settings)
        except ConfigurationError:
            raise
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception(
                "Keeper connection failed; reconnecting in %.1f seconds",
                settings.reconnect_delay_seconds,
            )
            await asyncio.sleep(settings.reconnect_delay_seconds)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logging.getLogger("web3").setLevel(logging.WARNING)

    try:
        settings = Settings.from_environment()
        asyncio.run(run_keeper(settings))
    except ConfigurationError as exc:
        LOGGER.error("Configuration error: %s", exc)
        return 2
    except KeyboardInterrupt:
        LOGGER.info("Keeper stopped")

    return 0


if __name__ == "__main__":
    sys.exit(main())
