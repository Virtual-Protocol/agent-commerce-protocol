# Agent Commerce Protocol (ACP)

A modular, cross-chain protocol for agent commerce—breaking down **accounts** into **jobs** and **jobs** into **memos**, with LayerZero v2 for cross-chain messaging and asset transfers.

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the [MIT License](LICENSE).

---

## Overview

- **ACPRouter** – Central router with upgradeable modules: AccountManager, JobManager, MemoManager, PaymentManager.
- **AssetManager** – Cross-chain asset transfers via LayerZero OApp (transfer requests, executions, confirmations).
- **Networks** – Ethereum, Base, Polygon, Arbitrum, BNB (mainnets and testnets) with configurable DVNs and options.

Contracts are UUPS-upgradeable, use OpenZeppelin AccessControl, and target Solidity `0.8.30` with the Cancun EVM.

---

## Project Structure

```
agent-commerce-protocol/
├── contracts/acp/
│   ├── v1/                    # Legacy (ACPSimple, InteractionLedger)
│   └── v2/
│       ├── ACPRouter.sol       # Main router
│       ├── interfaces/        # IAccountManager, IJobManager, IMemoManager, IPaymentManager, IAssetManager
│       ├── libraries/         # ACPTypes, ACPErrors, ACPConstants, ACPCodec, MemoValidation
│       └── modules/           # AccountManager, JobManager, MemoManager, PaymentManager, AssetManager
├── scripts/crosschain/
│   ├── contracts/             # Foundry scripts (Deploy, ConfigureLZ, SetPeers, SetEnforcedOptions, Upgrade)
│   ├── shell/                 # Shell scripts for deploy, configure, verify, upgrade
│   └── networks/              # mainnets.sample.json, testnets.sample.json
├── test/
│   ├── v1/                    # Legacy tests
│   └── v2/                    # Unit, integration, crosschain, e2e tests
├── foundry.toml
└── README.md
```

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- [jq](https://jqlang.github.io/jq/) (for cross-chain shell scripts)
- Node.js (for OpenZeppelin packages via `node_modules`)

---

## Setup

1. **Clone and install dependencies**

   ```bash
   git clone <repo-url>
   cd agent-commerce-protocol
   forge install
   npm install   # if using node_modules for OZ/remappings
   ```

2. **Copy network config (for deployment/scripts)**

   ```bash
   cp scripts/crosschain/networks/mainnets.sample.json scripts/crosschain/networks/mainnets.json
   cp scripts/crosschain/networks/testnets.sample.json scripts/crosschain/networks/testnets.json
   ```

   Edit the `*.json` files: set `rpcUrl` (and any other overrides) per network.

3. **Environment**

   Create a `.env` in the repo root (see scripts for required vars). Typical variables:

   - `ACCOUNT` – Foundry/cast account name used for deploy and config
   - `ASSET_MANAGER` – Deployed AssetManager address (for LZ/peer/enforced-options scripts)
   - RPC URLs: `ETH_RPC_URL`, `BASE_RPC_URL`, `POLYGON_RPC_URL`, `ARBITRUM_RPC_URL`, `BNB_RPC_URL`
   - Testnet RPCs: `ETH_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_RPC_URL`, etc.
   - Explorer API keys: `ETHERSCAN_API_KEY`, `BASESCAN_API_KEY`, `POLYGONSCAN_API_KEY`, `ARBISCAN_API_KEY`, `BSCSCAN_API_KEY`

   Ensure the account is in your cast wallet: `cast wallet import <key> --interactive`.

---

## Build & Test

```bash
# Build
forge build

# Run all tests
forge test

# Run tests under test/v2 (e.g. AssetManager)
forge test --match-path "test/v2/*.sol" -vvv
```

---

## Deployment & Cross-Chain Scripts

Scripts assume `.env` is loaded and `scripts/crosschain/networks/{mainnets|testnets}.json` exist.

| Script | Purpose |
|--------|--------|
| `scripts/crosschain/shell/deployAssetManager.sh` | Deploy AssetManager (proxy + impl) on each network |
| `scripts/crosschain/shell/configureLZ.sh` | Configure LayerZero (peers, path) – directional or full mesh |
| `scripts/crosschain/shell/setEnforcedOptions.sh` | Set LayerZero enforced options (DVNs, gas, etc.) |
| `scripts/crosschain/shell/configureAssetManagerFees.sh` | Set platform fee and treasury on AssetManager |
| `scripts/crosschain/shell/setPeer.sh` | Set a single peer for AssetManager |
| `scripts/crosschain/shell/setMemoManager.sh` | Set MemoManager on AssetManager (Base) |
| `scripts/crosschain/shell/upgradeAssetManager.sh` | Upgrade AssetManager implementation |
| `scripts/crosschain/shell/verify*.sh` | Verify deployment, LZ config, peers, enforced options, explorer |

**Examples**

```bash
# Deploy AssetManager on testnets
./scripts/crosschain/shell/deployAssetManager.sh testnet

# Configure LZ (will prompt for directional vs bidirectional)
./scripts/crosschain/shell/configureLZ.sh testnet

# Set enforced options
./scripts/crosschain/shell/setEnforcedOptions.sh testnet
```

---

## Network Configuration

- **LayerZero v2 endpoints** – Testnet and mainnet endpoint addresses are fixed in the scripts (e.g. `configureLZ.sh`).
- **Chain config** – Each network in `mainnets.json` / `testnets.json` includes `name`, `chainId`, `eid`, `rpcUrl`, `explorerSlug`, send/receive libs, executor, DVNs, and confirmation counts.
- **RPC & Etherscan** – `foundry.toml` references env vars for RPC and Etherscan APIs; ensure they are set when running forge scripts or verification.

---

## Key Contracts

| Contract | Description |
|----------|-------------|
| **ACPRouter** | Entrypoint: accounts → jobs → memos; manages modules, fees, and access control |
| **AssetManager** | LayerZero OApp: cross-chain transfer request/execute/confirm and fee handling |
| **MemoManager** | Memo lifecycle and integration with AssetManager for cross-chain payments |
| **AccountManager** | Account creation and participant management |
| **JobManager** | Job creation and linking to accounts |
| **PaymentManager** | Payment handling and platform/evaluator fees |

---

## License

MIT License. See [LICENSE](LICENSE).
