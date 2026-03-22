# Architecture

## Overview

The Encrypted DAO follows Aragon's plugin-based architecture: a core DAO contract handles treasury and execution, while governance plugins (token voting, multisig) determine _when_ execution is authorized. All sensitive data is encrypted using Zama's fhEVM Fully Homomorphic Encryption.

## Contract Inheritance

All contracts inherit `ZamaEthereumConfig` from `@fhevm/solidity`, which automatically configures the FHE coprocessor addresses based on the chain ID (mainnet, Sepolia, or local Hardhat).

```
ZamaEthereumConfig     ERC2771Context
       │                     │
       ├─────────┬───────────┤
       │         │           │
      DAO   EncryptedGov  EncryptedTokenVoting
             Token         EncryptedMultisig
```

All contracts also inherit `ERC2771Context` for meta-transaction support.

## Core Contracts

### DAO.sol

The central treasury and executor. Holds ETH and executes batched `Action[]` arrays when called by authorized plugins.

**Key design decisions:**
- Permission mappings are private — no public getter enumerates who has what role
- Events emit only the permission ID, not the addresses involved
- Uses `_msgSender()` throughout for meta-transaction compatibility

**Permission system:**
```
_permissionHash(where, who, permissionId) = keccak256(abi.encodePacked(where, who, permissionId))
```

Two built-in permissions:
- `ROOT_PERMISSION` — can grant/revoke other permissions
- `EXECUTE_PERMISSION` — can call `dao.execute()`

### EncryptedGovernanceToken.sol

ERC20-like token where all balances and voting power are encrypted (`euint64`). Only `totalSupply` is public (needed for quorum calculations).

**Checkpoint-based voting power snapshots:**

When a voting plugin creates a proposal, it calls `createSnapshot()`. The token records each account's voting power at that moment using copy-on-write checkpoints. Subsequent transfers don't affect already-snapshotted values.

```
createSnapshot() → currentSnapshotId = N

Before any _votingPower[account] modification:
  if no checkpoint at snapshotId N for this account:
    save checkpoint(N, current_power)    ← copy-on-write

getSnapshotVotingPower(N, account):
  search backwards through checkpoints
  return latest checkpoint at or before N
```

This prevents "vote and dump" attacks — voters' power is locked at proposal creation time.

**Token holder registry:**
The `isTokenHolder` mapping tracks addresses that have ever held tokens. This flag is set on mint/transfer-receive and never cleared (since encrypted balances can't be checked for zero without decryption). This is a conservative superset.

**Delegation:**
Accounts can delegate voting power. The delegation graph (who delegates to whom) is public, but the delegated amounts are encrypted.

### EncryptedTokenVoting.sol

Token-weighted voting plugin implementing four privacy improvements:

1. **Snapshotted voting power** — `createProposal()` calls `governanceToken.createSnapshot()`. `vote()` reads `getSnapshotVotingPower(snapshotId, voter)` instead of current balance.

2. **On-chain encrypted calldata** — the full `Action[]` is ABI-encoded, split into 32-byte chunks, encrypted as `euint256[]`, and stored on-chain. No off-chain data sharing needed.

3. **Identity-free proposals** — anyone can call `createProposal()` (no token holder check). Non-holder proposals simply never reach quorum. Cancellation uses a `cancelKeyHash` instead of proposer identity.

4. **Meta-transactions** — all operations use `_msgSender()` via EIP-2771.

### EncryptedMultisig.sol

N-of-M multisig with the same four improvements:

- Signer identities stored as `ebool` flags — anyone can call `approve()`, but non-signers silently contribute zero via `FHE.select(callerIsSigner, one, zero)`
- On-chain encrypted calldata chunks
- Identity-free proposals with cancel key hash
- Meta-transaction support

Signer management (`addSigner`, `removeSigner`, `setThreshold`) can only be called by the DAO itself (via governance proposals).

### ERC2771Context.sol

Minimal EIP-2771 implementation. When `msg.sender` is the trusted forwarder, the real sender is extracted from the last 20 bytes of calldata. Observers see only the forwarder's address in transaction logs.

### IDAO.sol

Interface defining the `Action` struct (`to`, `value`, `data`) and `execute()` function signature. Both plugins interact with the DAO through this interface.

## Data Flow

### Encrypted Calldata (euint256 chunks)

Proposals store actions as encrypted on-chain data:

```
Client-side:
  Action[] → abi.encode() → pad to 32-byte boundary → split into chunks → encrypt each as euint256

On-chain storage:
  mapping(uint256 => euint256[]) _encryptedChunks

Reveal (after approval):
  FHE.makePubliclyDecryptable(chunks) → KMS decrypts → uint256[] stored in _revealedChunks

Execution:
  _revealedChunks → reassemble bytes → abi.decode as Action[] → dao.execute()
```

### FHE ACL (Access Control List)

The FHE ACL controls who can decrypt encrypted values:
- `FHE.allowThis(handle)` — the contract itself can use the value
- `FHE.allow(handle, address)` — a specific address can decrypt
- `FHE.allowTransient(handle, address)` — temporary access within a transaction
- `FHE.makePubliclyDecryptable(handle)` — anyone can decrypt (used for finalization)

### Cross-Contract Communication

The governance token grants `FHE.allowTransient()` to the calling voting plugin when `getSnapshotVotingPower()` is called. This allows the plugin to use the encrypted voting power value within the same transaction without persisting access.

## What is Public (by design)

| Component | Why |
|---|---|
| Total token supply | Needed for quorum percentage calculation |
| Member/signer count | Needed for threshold validation |
| Quorum and threshold parameters | Governance rules should be transparent |
| Delegation graph (who → whom) | Standard in governance (amounts are hidden) |
| Proposal timing (start/end dates) | Voters need to know when to participate |
| Pass/fail result | Required to decide whether to execute |
| Revealed actions after approval | Required to execute on-chain |
| Forwarder address in tx logs | Inherent to EIP-2771 (real caller is hidden) |
