# Deployment

## Prerequisites

- Node.js >= 20
- npm >= 7

```bash
npm install
npm run compile
```

## Local Deployment (Hardhat Network)

The simplest way to deploy — uses the fhEVM mock environment with `@fhevm/hardhat-plugin`.

```bash
# Start a local Hardhat node
npm run chain

# In another terminal, deploy
npm run deploy:localhost
```

## Sepolia Testnet

### 1. Configure credentials

Hardhat vars are used for sensitive configuration (no `.env` file needed):

```bash
npx hardhat vars set MNEMONIC "your twelve word mnemonic phrase here"
npx hardhat vars set INFURA_API_KEY "your_infura_api_key"
npx hardhat vars set ETHERSCAN_API_KEY "your_etherscan_key"  # optional, for verification
```

### 2. Deploy

```bash
npm run deploy:sepolia
```

### 3. Verify contracts (optional)

```bash
npx hardhat verify --network sepolia <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS...>
```

## Deployment Script

The deployment script (`deploy/deploy.ts`) uses `hardhat-deploy` and deploys in this order:

1. **DAO** — core treasury and executor
2. **EncryptedGovernanceToken** — governance token with encrypted balances
3. **EncryptedTokenVoting** — token-weighted voting plugin
4. Post-deployment setup:
   - Authorize voting plugin as snapshot creator on the token
   - Grant `EXECUTE_PERMISSION` to voting plugin on the DAO

### Optional: Multisig Plugin

Set environment variables before deploying:

```bash
DEPLOY_MULTISIG=true \
MULTISIG_SIGNERS=0xAddr1,0xAddr2,0xAddr3 \
MULTISIG_THRESHOLD=2 \
npm run deploy:sepolia
```

### Trusted Forwarder (EIP-2771)

To enable meta-transactions for caller privacy, set the forwarder address:

```bash
TRUSTED_FORWARDER=0xYourForwarderAddress npm run deploy:sepolia
```

If not set, defaults to `address(0)` (meta-transactions disabled).

## What Gets Deployed

| Contract | Constructor Args |
|---|---|
| `DAO` | `(deployer, trustedForwarder)` |
| `EncryptedGovernanceToken` | `("Encrypted Gov Token", "eGOV", trustedForwarder)` |
| `EncryptedTokenVoting` | `(dao, token, 7 days, 20% quorum, 50% support, 100 min balance, trustedForwarder)` |
| `EncryptedMultisig` (optional) | `(dao, signers[], threshold, 30 days, trustedForwarder)` |

## Network Configuration

All contracts inherit `ZamaEthereumConfig` from `@fhevm/solidity`, which auto-resolves coprocessor addresses:

| Network | Chain ID | ACL / Executor / KMS |
|---|---|---|
| Hardhat (local) | 31337 | Mock addresses (handled by `@fhevm/hardhat-plugin`) |
| Sepolia | 11155111 | Zama's deployed Sepolia contracts |
| Ethereum | 1 | Zama's deployed mainnet contracts |

No manual address configuration is needed.

## Post-Deployment: Transferring Ownership

After deployment, the deployer holds `ROOT_PERMISSION`. In production, transfer ROOT to the DAO itself:

```solidity
// Grant ROOT to the DAO
dao.grant(address(dao), address(dao), dao.ROOT_PERMISSION_ID());

// Revoke ROOT from the deployer
dao.revoke(address(dao), deployer, dao.ROOT_PERMISSION_ID());
```

This makes the DAO self-governing — only governance proposals can modify permissions.
