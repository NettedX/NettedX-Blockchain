# NettedX Blockchain

NettedX Blockchain is the smart contract layer of the NettedX settlement system.

The project implements blockchain-based trade netting and settlement using Solidity and Foundry. It includes settlement management, netting, liquidity pool management, ERC-20 test tokens, and dashboard metrics accessible through Ethereum JSON-RPC.

## Prerequisites

Make sure the following tools are installed:

* Foundry
* Git

On macOS, Foundry can be installed with Homebrew:

```bash
brew install foundry
```

Verify the installation:

```bash
forge --version
```

You should also have `cast` and `anvil` available:

```bash
cast --version
anvil --version
```

## Get Started

> For developers.
> Quickstart for users is available in the [Docker Deployment](#docker-deployment) section.

### Clone the Repository

Clone the repository together with all Git submodules:

```bash
git clone --recurse-submodules https://github.com/NettedX/NettedX-Blockchain.git
cd NettedX-Blockchain
```

If you have already cloned the repository without submodules, initialize them with:

```bash
git submodule update --init --recursive
```

Verify the dependencies:

```bash
git submodule status
```

You should see the required dependencies under:

```text
lib/forge-std
lib/openzeppelin-contracts
```

### Build

Compile all Solidity contracts:

```bash
forge build
```

To display contract bytecode sizes:

```bash
forge build --sizes
```

### Local Development

Start a local Anvil node:

```bash
anvil
```

The default RPC endpoint is:

```text
http://127.0.0.1:8545
```

Then deploy or interact with contracts using Foundry's `forge` command.

```bash
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

From now on, all contracts have been deployed to the local Anvil blockchain, and you can start the Backend via RPC to interact with the smart contracts.

## Available Commands

### Format

Check whether the contracts follow the project's formatting rules:

```bash
forge fmt --check
```

To automatically format the code:

```bash
forge fmt
```

### Test

Run the complete test suite:

```bash
forge test -vvv
```

For more detailed execution traces:

```bash
forge test -vvvv
```

You can also run a specific test file:

```bash
forge test --match-path test/unit/Netting.t.sol -vvv
```

The test suite covers the main components of the system, including:

* Netting
* Settlement
* LiquidityPool
* Mock tokens
* End-to-end settlement flow

## Contract Interaction

After deployment, contract addresses can be used with `cast` to interact with the blockchain.

For example, check the available Anvil accounts:

```bash
cast rpc eth_accounts --rpc-url http://127.0.0.1:8545
```

Read the current settlement window:

```bash
cast call \
  $NETTING \
  "currentWindowId()(uint256)" \
  --rpc-url $RPC_URL
```

The main contracts are:

```text
Netting
Settlement
LiquidityPool
MockUSDC
MockBond
```

## ABI

After running:

```bash
forge build
```

Foundry generates contract artifacts under:

```text
out/
```

For example:

```text
out/Netting.sol/Netting.json
```

The generated artifact contains the contract ABI and bytecode.

The ABI can be used by the backend or frontend to interact with the deployed smart contract.

## Environment Variables

For local development, you can use a `.env` file:

```text
RPC_URL=http://127.0.0.1:8545
PRIVATE_KEY=your_private_key
```

Do not commit private keys to GitHub.

Make sure `.env` is included in `.gitignore`:

```text
.env
```

## Docker Deployment

> For production or users.

The project provides a Dockerized development environment containing an Anvil private blockchain and the NettedX smart contracts.

### Prerequisites

- Docker
- Docker Compose
- Cloned repository with submodules initialized

No local Foundry installation is required.

### Configuration

Copy the example environment file:

```bash
cp .env.example .env
```

Change the variables in `.env` as needed.

### Build and Run

```bash
docker-compose up --build
```

## Common Dependency Issues

If Foundry reports dependency or submodule errors, first make sure all submodules are initialized and synchronized:

```bash
git submodule update --init --recursive
```

Check the current submodule revisions:

```bash
git submodule status
```

If a dependency is marked as `dirty`, for example:

```text
cab19933...-dirty
```

the dependency contains local uncommitted changes. Inspect them before continuing:

```bash
cd lib/openzeppelin-contracts
git status
git diff
```

If the changes are unintended, restore the dependency:

```bash
git reset --hard
git clean -fd
```

Then return to the project root:

```bash
cd ../..
```

Finally, verify that the working tree is clean:

```bash
git status
```

### CI

Every push and pull request runs the Foundry CI pipeline, which checks:

1. Foundry installation
2. Solidity formatting
3. Contract compilation
4. Contract bytecode sizes
5. Complete test suite

You can run the same checks locally before pushing:

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

## Project Structure

The main project structure is:

```text
NettedX-Blockchain/
├── src/
│   ├── core/
│   │   ├── Netting.sol
│   │   ├── Settlement.sol
│   │   └── LiquidityPool.sol
│   ├── interfaces/
│   └── libraries/
├── test/
│   ├── unit/
│   └── integration/
├── script/
│   └── Deploy.s.sol
├── lib/
│   ├── forge-std/
│   └── openzeppelin-contracts/
├── foundry.toml
├── .gitmodules
└── README.md
```

## Development Workflow

The recommended local development workflow is:

```text
Clone Repository
      ↓
Initialize Submodules
      ↓
Build Contracts
      ↓
Run Tests
      ↓
Start Anvil
      ↓
Deploy Contracts
      ↓
Get Contract Addresses
      ↓
Interact Using cast
      ↓
Connect Backend / Frontend
```

## Repository

GitHub:

[NettedX-Blockchain](https://github.com/NettedX/NettedX-Blockchain.git?utm_source=chatgpt.com)
