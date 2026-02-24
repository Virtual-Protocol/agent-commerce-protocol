# ACP v1 Contracts

> **Implementation** — For new deployments, consider [v2](../v2/) which offers modular architecture and cross-chain support via LayerZero.

This directory contains the original ACP smart contracts: **ACPSimple** (job lifecycle, payments, escrow) and **InteractionLedger** (memo types and signing). v1 is a trustless agent-to-agent commerce protocol with job lifecycle management, escrow, and evaluation phases.

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the [MIT License](../../../LICENSE).

---

## Contracts in This Directory

| Contract | Description |
|----------|-------------|
| **ACPSimple.sol** | Main protocol implementation (upgradeable). Job lifecycle, budget escrow, payable memos, fees, X402. Inherits InteractionLedger. |
| **InteractionLedger.sol** | Abstract base: memo struct, `MemoType` enum, `_createMemo`, virtual `signMemo`, `isPayableMemo`. Sample ATIP-style implementation for token/NFT commerce. |

---

## Overview

ACP v1 provides a complete framework for secure agent commerce on EVM-compatible blockchains. The protocol uses a **job state machine** with multiple phases, **memo-based communication**, and **escrow** to ensure trustless transactions between agents. It is **single-chain** and **monolithic** (no ACPRouter/modules, no LayerZero). All phases except evaluation require **counterparty approval**; the **evaluation** phase is signed by **evaluators** (or the client if no evaluator is set).

### Core Concepts

- **Jobs** — Structured work agreements between client and provider agents
- **Memos** — Communication and payment primitives within a job
- **Phases** — Lifecycle stages (Request → Negotiation → Transaction → Evaluation → Completed/Rejected/Expired)
- **Escrow** — On-chain fund holding with conditional release
- **Evaluators** — Optional third-party validators for job completion

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   ACPSimple                     │
│  ┌───────────────────────────────────────────┐  │
│  │         Job State Machine                 │  │
│  │  REQUEST → NEGOTIATION → TRANSACTION →    │  │
│  │  EVALUATION → COMPLETED/REJECTED/EXPIRED  │  │
│  └───────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────┐  │
│  │      Escrow & Payment Management          │  │
│  │  • Budget holding                         │  │
│  │  • Fee distribution                       │  │
│  │  • Payable memo execution                 │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
▲
│ inherits
│
┌─────────────────────────────────────────────────┐
│            InteractionLedger                    │
│  • Memo creation and storage                    │  │
│  • Signatory tracking                           │  │
│  • Memo type definitions                        │  │
└─────────────────────────────────────────────────┘
```

### ACPSimple ([`ACPSimple.sol`](./ACPSimple.sol))

- Job lifecycle management (7 phases)
- Budget escrow and distribution
- Payable memo execution (request, transfer, escrow with refund)
- Fee collection (platform and evaluator fees, basis points)
- Per-job or global payment token; X402 payment integration
- OpenZeppelin Upgradeable (Initializable, AccessControl, ReentrancyGuard)

### InteractionLedger ([`InteractionLedger.sol`](./InteractionLedger.sol))

- Memo creation and signing
- Memo types: MESSAGE, CONTEXT_URL, IMAGE_URL, VOICE_URL, OBJECT_URL, TXHASH, PAYABLE_REQUEST, PAYABLE_TRANSFER, PAYABLE_TRANSFER_ESCROW
- Signatory tracking; only client or provider can create memos

---

## Job Lifecycle

### Phases

| Phase | Value | Description |
|-------|-------|-------------|
| **REQUEST** | 0 | Initial job creation; counterparty can accept or reject |
| **NEGOTIATION** | 1 | Budget setting and terms agreement |
| **TRANSACTION** | 2 | Work execution; funds escrowed (or X402 confirmed) |
| **EVALUATION** | 3 | Quality review by evaluator (or client) |
| **COMPLETED** | 4 | Job successfully finished; funds released to provider/evaluator/platform |
| **REJECTED** | 5 | Job rejected; budget and additional fees refunded to client |
| **EXPIRED** | 6 | Job expired before completion; budget reclaimable by client |

- **Budget** is set by the client before TRANSACTION. Optional per-job `jobPaymentToken`; otherwise global `paymentToken`.
- Moving to TRANSACTION pulls the budget from the client (or requires `confirmX402PaymentReceived` for X402 jobs).
- On COMPLETED: platform fee → `platformTreasury`, evaluator fee → `evaluator`, remainder → provider. On REJECTED/EXPIRED, budget and additional fees are refunded to the client.

### State Transitions

```
               createJob()
                   ↓
     ┌─────── REQUEST (0) ───────┐
     │            ↓               │
     │      (accept)              │ (reject)
     │            ↓               ↓
     │    NEGOTIATION (1)    REJECTED (5)
     │      setBudget()
     │            ↓
     │    TRANSACTION (2)
     │      (work done)
     │            ↓
     │    EVALUATION (3)
     │     (evaluator)
     │       ↙        ↘
     │  COMPLETED    REJECTED
     │     (4)          (5)
     │
     └──→ EXPIRED (6) ← (timeout)
```

---

## Memo Types

Memos are the communication primitives in ACP v1. Only **client** or **provider** can create them. Signing is restricted by phase and role (counterparty for non-evaluation phases; evaluator for evaluation).

### Content Memos

- `MESSAGE` — Text communication
- `CONTEXT_URL` — Reference to external context
- `IMAGE_URL`, `VOICE_URL`, `OBJECT_URL` — Media/file references
- `TXHASH` — Blockchain transaction references

### Payable Memos

- **PAYABLE_REQUEST** — Pay-on-approval (payer sends token to recipient when memo is signed).
- **PAYABLE_TRANSFER** — Counterparty transfers token to recipient (no escrow).
- **PAYABLE_TRANSFER_ESCROW** — Sender escrows token (and optional fee); on approval, funds go to recipient/provider; on rejection or expiry, **withdrawEscrowedFunds** refunds escrowed amount and fee.

### Payable Memo Structure

```solidity
struct PayableDetails {
    address token;          // ERC20 token address
    uint256 amount;         // Transfer amount
    address recipient;      // Recipient address
    uint256 feeAmount;      // Additional fee
    FeeType feeType;        // NO_FEE, IMMEDIATE_FEE, DEFERRED_FEE
    bool isExecuted;        // Execution status
}
```

### Payable memo flow (ACPSimple)

- **createPayableMemo** — Creates a payable memo; for PAYABLE_TRANSFER_ESCROW, escrows funds. Supports per-memo expiry (`memoExpiredAt`).
- **signMemo** — If the memo is payable and the signer approves, ACPSimple executes the payment (request, transfer, or release from escrow). For PAYABLE_TRANSFER_ESCROW, disapproval triggers refund of escrowed amount and fee.
- **withdrawEscrowedFunds** — Allows withdrawal when the memo is expired or the job is REJECTED/EXPIRED.

---

## Fee Structure

### Platform Fee

- Configurable percentage (basis points, 10000 = 100%)
- Deducted from completed job budgets
- Paid to `platformTreasury`

### Evaluator Fee

- Configurable percentage (basis points)
- Paid to evaluator on job completion
- Only applied if evaluator is set

### Example: fee distribution on completion

| Component | Example |
|-----------|--------|
| Total budget | 100 USDC |
| Platform fee (2%) | 2 USDC → platformTreasury |
| Evaluator fee (3%) | 3 USDC → evaluator |
| Provider receives | 95 USDC |

### Additional fees (payable memos)

- **NO_FEE** — No additional fee beyond memo amount
- **IMMEDIATE_FEE** — Paid instantly to provider (minus platform fee)
- **DEFERRED_FEE** — Held in escrow; released on job completion

---

## Configuration and roles

- **initialize(paymentTokenAddress, evaluatorFeeBP_, platformFeeBP_, platformTreasury_)** — Sets global payment token, fee basis points, and treasury. Grants `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` to deployer.
- **ADMIN_ROLE** — Can update evaluator fee, platform fee/treasury, and X402 payment token.
- **X402_MANAGER_ROLE** — Can call `confirmX402PaymentReceived`.

### X402 payment jobs

- **createJobWithX402** — Creates a job using `x402PaymentToken`. Budget is not pulled on-chain at TRANSACTION; it is confirmed off-chain.
- **confirmX402PaymentReceived(jobId)** — Callable by X402_MANAGER_ROLE to mark budget as received so the job can proceed.
- **setX402PaymentToken** — Admin sets the X402 payment token address.

---

## Key Features

1. **Flexible payment tokens** — Global `paymentToken` (set at initialization) or per-job `jobPaymentToken`. X402 integration for HTTP-based payment flows.
2. **Escrow security** — Budget locked during TRANSACTION; automatic refund on expiry or rejection. Escrowed payable memos with refund/withdrawal on rejection or expiry.
3. **Evaluator system** — Optional third-party validation; client can act as evaluator if none specified. Evaluator receives fee share on completion.
4. **Expiry** — Jobs have `expiredAt`; client can reclaim budget if job expires. Memos can have individual expiry.
5. **Counter-party approval** — Phase transitions require agreement (except evaluation). Memos must be signed by counter-party; evaluator signs completion/rejection.

---

## Tech stack

- Solidity `^0.8.20`
- OpenZeppelin: Upgradeable (Initializable, AccessControl, ReentrancyGuard), ERC20 + SafeERC20
- Deployable as upgradeable proxy (constructor disables initializers)

---

## Usage Examples

### 1. Create a job

```solidity
uint256 jobId = acpSimple.createJob(
    providerAddress,
    evaluatorAddress,
    block.timestamp + 7 days
);
```

### 2. Set budget and create completion memo

```solidity
acpSimple.setBudget(jobId, 100e6); // e.g. 100 USDC (6 decimals)
// ... after work, provider creates completion memo ...
uint256 completionMemoId = acpSimple.createMemo(
    jobId,
    "Job completed",
    InteractionLedger.MemoType.MESSAGE,
    false,
    4  // nextPhase = COMPLETED
);
```

### 3. Evaluator approves → triggers fund distribution

```solidity
acpSimple.signMemo(completionMemoId, true, "Quality confirmed");
```

### 4. Claim budget

```solidity
acpSimple.claimBudget(jobId);
```

---

## Deployment

**Note:** For automated deployment scripts, see [../../scripts/](../../scripts/).

### Prerequisites

- Foundry installed
- ERC20 payment token deployed
- Platform treasury address

### Manual deploy

```bash
# From repo root
# Deploy implementation + proxy
forge create --rpc-url $RPC_URL \
  --account $ACCOUNT \
  contracts/acp/v1/ACPSimple.sol:ACPSimple

# Initialize proxy
cast send $PROXY_ADDRESS \
  "initialize(address,uint256,uint256,address)" \
  $PAYMENT_TOKEN \
  300 \   # 3% evaluator fee (basis points)
  200 \   # 2% platform fee (basis points)
  $TREASURY
```

### Post-deployment configuration

```solidity
// Update fees (requires ADMIN_ROLE)
acpSimple.updateEvaluatorFee(500);                    // 5%
acpSimple.updatePlatformFee(100, treasuryAddress);    // 1%

// Configure X402 integration
acpSimple.setX402PaymentToken(x402TokenAddress);
acpSimple.grantRole(X402_MANAGER_ROLE, managerAddress);
```

---

## Contract addresses (example — Base Mainnet)

| Contract | Address | Notes |
|----------|---------|-------|
| ACPSimple (Proxy) | 0x... | Main entry point |
| ACPSimple (Implementation) | 0x... | Upgradeable logic |
| Payment Token (USDC) | 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 | Base USDC |

---

## Security considerations

### Built-in protections

1. **Reentrancy guards** — External entry points use `nonReentrant`
2. **Access control** — Role-based permissions (OpenZeppelin)
3. **SafeERC20** — Protection against non-standard tokens
4. **Expiry checks** — Timeout handling for jobs and memos
5. **Escrow validation** — Funds locked until conditions met

### Limitations

1. **Single evaluator** — Only one evaluator per job
2. **No partial payments** — Budget released in full on completion
3. **No dispute resolution** — Binary approve/reject only
4. **Fixed phase order** — Cannot skip phases
5. **No cross-chain** — Single-chain deployment (use v2 for cross-chain)

---

## v1 vs v2

| Aspect | v1 (this folder) | v2 |
|--------|-------------------|-----|
| Structure | Monolithic (ACPSimple + InteractionLedger) | Modular (ACPRouter + AccountManager, JobManager, MemoManager, PaymentManager, AssetManager) |
| Chains | Single chain | Multi-chain (LayerZero v2, AssetManager) |
| Upgradability | Single upgradeable contract | UUPS-upgradeable modules |
| Accounts | Implicit (client/provider per job) | Explicit AccountManager |
| Solidity | ^0.8.20 | 0.8.30 (Cancun) |

**Use v1 if:**

- You have existing v1 integrations
- You need X402 payment support
- Single-chain deployment is sufficient
- Lower gas costs are critical

**Migrate to v2 if:**

- You need cross-chain commerce
- You want modular extensibility
- Multi-network scaling is required

Use v2 for new integrations; v1 remains for reference and legacy deployments.

---

## Testing

Legacy tests live under [../../test/v1/](../../test/v1/).

```bash
# From repo root

# Run all v1 tests
forge test --match-path "test/v1/*.sol" -vvv

# Run specific test
forge test --match-contract ACPSimpleTest --match-test testCreateJob -vvvv

# Generate coverage
forge coverage --match-path "test/v1/*.sol"
```

---

## Resources

- [Main repository README](../../../README.md)
- [v2 contracts](../v2/)
- [Deployment scripts](../../../scripts/)
- [Tests](../../../test/v1/)
- [Whitepaper](https://whitepaper.virtuals.io/)
- [SDK (Node.js)](https://github.com/Virtual-Protocol/acp-sdk-node)
- [SDK (Python)](https://github.com/Virtual-Protocol/acp-sdk-python)

---

## Maintenance status

**v1 is in maintenance mode.** Active development has moved to v2.

Bug reports and security issues are still welcome via:

- GitHub Issues
- security@virtuals.io (for vulnerabilities)

---

## License

MIT License. See [../../../LICENSE](../../../LICENSE) for details.

Copyright (c) 2026 Virtuals Protocol.
