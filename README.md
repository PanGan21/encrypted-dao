# Encrypted DAO — Private Governance Framework using FHE

A modular, Aragon-inspired DAO framework where governance is fully private. Built on Zama's fhEVM, every vote, balance, approval, and proposal is encrypted using Fully Homomorphic Encryption (FHE).

## Quick Start

```bash
# Install dependencies
npm install

# Compile contracts
npm run compile

# Run tests (uses fhEVM mock on local Hardhat)
npm test

# Run E2E tests (proxy deployment, upgrades, full proposal lifecycle)
npm run test:e2e

# Start local chain + run E2E tests against it
npm run chain          # terminal 1
npm run test:e2e:localhost  # terminal 2

# Deploy locally
npm run chain          # terminal 1
npm run deploy:localhost    # terminal 2

# Deploy to Sepolia
npx hardhat vars set MNEMONIC
npx hardhat vars set INFURA_API_KEY
npm run deploy:sepolia
```

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                        DAO.sol                           │
│         Treasury · Batched Execution · Permissions       │
│         EIP-2771 meta-transactions                       │
└───────────┬──────────────────────────┬───────────────────┘
            │  dao.execute()           │  dao.execute()
            │                          │
┌───────────┴───────────┐   ┌─────────┴───────────────────┐
│ EncryptedTokenVoting  │   │     EncryptedMultisig       │
│                       │   │                             │
│ Token-weighted votes  │   │  N-of-M signer approval    │
│ Snapshotted power     │   │  Threshold-based           │
│ On-chain enc calldata │   │  On-chain enc calldata     │
│ Identity-free propose │   │  Identity-free propose     │
│ EIP-2771 meta-tx      │   │  EIP-2771 meta-tx          │
└───────────┬───────────┘   └─────────────────────────────┘
            │
            │ getSnapshotVotingPower()
            │
┌───────────┴───────────┐
│ EncryptedGovToken     │
│                       │
│ Encrypted balances    │
│ Checkpoint snapshots  │
│ Delegation support    │
│ EIP-2771 meta-tx      │
└───────────────────────┘

┌───────────────────────┐
│  ERC2771Context.sol   │
│  (inherited by all)   │
│                       │
│  Trusted forwarder    │
│  _msgSender()         │
└───────────────────────┘
```

## Contracts

| Contract                                  | Description                                                                                        |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `DAO.sol`                                 | Core treasury and executor. Private permission mappings, batched action execution.                 |
| `EncryptedGovernanceToken.sol`            | ERC20-like token with encrypted balances, checkpoint-based voting power snapshots, delegation.     |
| `EncryptedTokenVoting.sol`                | Token-weighted voting plugin with encrypted votes, snapshotted power, on-chain encrypted calldata. |
| `EncryptedMultisig.sol`                   | N-of-M multisig plugin with hidden signer identities and encrypted approval tallies.               |
| `DAOUpgradeable.sol`                      | UUPS-upgradeable DAO with `UPGRADE_PERMISSION_ID` for governance-controlled upgrades.              |
| `DAOUpgradeableV2.sol`                    | Example V2 upgrade adding pause/unpause functionality.                                             |
| `EncryptedGovernanceTokenUpgradeable.sol` | UUPS-upgradeable governance token with FHE coprocessor proxy-safe init.                            |
| `ERC2771Context.sol`                      | Minimal EIP-2771 meta-transaction base contract.                                                   |
| `IDAO.sol`                                | Interface defining the `Action` struct and `execute()` function.                                   |

## Privacy Summary

| Component             | What's Hidden                            | How                                  |
| --------------------- | ---------------------------------------- | ------------------------------------ |
| **Balances**          | All token holdings                       | `euint64` encrypted storage          |
| **Voting power**      | Individual weight (current + historical) | Encrypted checkpoints                |
| **Votes**             | Direction and weight                     | `ebool` × snapshotted `euint64`      |
| **Tallies**           | Running and final vote counts            | `euint64`, only pass/fail revealed   |
| **Proposals**         | Full calldata (targets, values, data)    | `euint256[]` on-chain chunks         |
| **Proposer identity** | Who created the proposal                 | No membership check; cancel key hash |
| **Membership**        | Multisig signer identities               | `ebool` flags, silent zero-out       |
| **Permissions**       | DAO role assignments                     | Private mappings, minimal events     |
| **Caller identity**   | Who is interacting with contracts        | EIP-2771 trusted forwarder           |

## Documentation

Detailed documentation is in the [docs/](docs/) folder:

- [Architecture](docs/architecture.md) — contract design, inheritance, and data flow
- [Deployment](docs/deployment.md) — how to deploy to local, Sepolia, and mainnet
- [Testing](docs/testing.md) — test structure, running tests, writing new tests
- [Proposal Lifecycle](docs/proposal-lifecycle.md) — the 6-phase lifecycle from creation to execution

## Project Structure

```
encrypted-dao/
├── contracts/dao/       # Solidity contracts
├── deploy/              # hardhat-deploy deployment scripts
├── docs/                # Documentation
├── scripts/             # Utility scripts (proposal decryption)
├── test/                # Test files (89 tests, including E2E)
├── hardhat.config.ts    # Hardhat configuration
├── package.json         # Dependencies and scripts
└── tsconfig.json        # TypeScript configuration
```

## Based On

- [fhevm-hardhat-template](https://github.com/zama-ai/fhevm-hardhat-template) — project structure and tooling
- [@fhevm/solidity](https://www.npmjs.com/package/@fhevm/solidity) — FHE library
- [@fhevm/hardhat-plugin](https://www.npmjs.com/package/@fhevm/hardhat-plugin) — Hardhat integration with mock FHE for testing
- [Aragon OSx](https://aragon.org/) — DAO architecture inspiration (plugin pattern)

## License

BSD-3-Clause-Clear
