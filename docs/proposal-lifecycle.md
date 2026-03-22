# Proposal Lifecycle

Both `EncryptedTokenVoting` and `EncryptedMultisig` follow the same 6-phase lifecycle. The key difference is how approval works: token voting uses encrypted weighted votes, while multisig uses encrypted signer flags.

## State Machine

```
                  cancel()
    ┌──────────────────────────────────────┐
    │                                      ▼
 Create → View → Vote/Approve → Finalize → Reveal → Execute
  (1)     (2)      (3)           (4)        (5)      (6)
    │                              │
    │                              ▼
    │                          Defeated
    │                              │
    └──────────────────────────────┘
                cancel()
```

State enum values: `Active`, `Pending`, `Succeeded`, `Defeated`, `Revealed`, `Executed`, `Cancelled`.

---

## Phase 1: Create

**Function:** `createProposal(encHandles, inputProof, cancelKeyHash, [params])`

The proposer submits encrypted calldata chunks representing the `Action[]` to execute. No identity check is performed — anyone can create a proposal. Non-member proposals simply never reach quorum/threshold.

**Client-side preparation:**

```
Action[] → abi.encode() → pad to 32-byte boundary → split into chunks → encrypt each as euint256
```

Each chunk is encrypted client-side using `fhevm.createEncryptedInput()` and submitted as a `bytes32` handle with a single `inputProof`.

**What happens on-chain:**

| Step               | Token Voting                                         | Multisig                              |
| ------------------ | ---------------------------------------------------- | ------------------------------------- |
| Store chunks       | `FHE.fromExternal()` + `FHE.allowThis()` per chunk   | Same                                  |
| Snapshot           | `governanceToken.createSnapshot()`                   | N/A                                   |
| Initialize tallies | `encryptedForVotes = 0`, `encryptedAgainstVotes = 0` | `encryptedApprovals = 0`              |
| Set timing         | `voteStart` / `voteEnd` (custom or default)          | `createdAt` / `expiresAt` (automatic) |
| Store cancel key   | `cancelKeyHash`                                      | Same                                  |

**Privacy:** The proposer's identity is hidden (no membership check, no revert). The proposal content is encrypted on-chain.

---

## Phase 2: View

**Function:** `viewProposal(proposalId)`

Members request decryption access to the encrypted calldata chunks before voting/approving. This grants `FHE.allow(chunk, caller)` on every chunk.

|              | Token Voting                          | Multisig                    |
| ------------ | ------------------------------------- | --------------------------- |
| Who can view | Token holders (`isTokenHolder` check) | Signers (`_isSigner` check) |

**Privacy:** The `ProposalViewed` event reveals that someone viewed the proposal, but with EIP-2771 meta-transactions, the viewer's real address is hidden behind the forwarder.

---

## Phase 3: Vote / Approve

### Token Voting: `vote(proposalId, encryptedVote, inputProof)`

Voters submit an encrypted boolean vote weighted by their **snapshotted** voting power (locked at proposal creation time). This prevents "vote and dump" attacks.

```
voteChoice = FHE.fromExternal(encryptedVote, inputProof)
voterWeight = governanceToken.getSnapshotVotingPower(snapshotId, voter)

forWeight     = FHE.select(voteChoice, voterWeight, 0)
againstWeight = FHE.select(voteChoice, 0, voterWeight)

encryptedForVotes     += forWeight
encryptedAgainstVotes += againstWeight
```

Anyone can call `vote()` — zero-balance voters contribute zero weight with no revert.

### Multisig: `approve(proposalId)`

Signers approve the proposal. Non-signers silently contribute zero via the encrypted signer flag:

```
callerIsSigner = _encryptedSigners[sender]    // ebool
increment = FHE.select(callerIsSigner, 1, 0)  // euint64
encryptedApprovals += increment
```

Anyone can call `approve()` — non-signers add zero with no revert.

**Privacy:** In both cases, the `VoteCast` / `Approved` event reveals that someone participated but not their identity (with EIP-2771) or their vote direction / signer status.

---

## Phase 4: Finalize

**Function:** `finalize(proposalId, decryptionProof, abiEncodedCleartexts)`

After the voting period ends (token voting) or at any time (multisig), anyone can trigger finalization. This reveals only the pass/fail result — not individual votes or tallies.

### Token Voting

```
totalVotes = encryptedForVotes + encryptedAgainstVotes
meetsQuorum = totalVotes >= (totalSupply * minQuorumPct / 100)
hasMajority = encryptedForVotes > encryptedAgainstVotes
approved = meetsQuorum AND hasMajority
```

### Multisig

```
meetsThreshold = encryptedApprovals >= threshold
```

### KMS Decryption

In both cases:

1. The result (`approved` or `meetsThreshold`) is made publicly decryptable via `FHE.makePubliclyDecryptable()`
2. The KMS provides a `decryptionProof` and `abiEncodedCleartexts`
3. `FHE.checkSignatures()` verifies the KMS proof (reverts on failure)
4. The decoded boolean is stored as `resultApproved`

**State after finalize:**

- `resultApproved = true` → state becomes `Succeeded`
- `resultApproved = false` → state becomes `Defeated` (lifecycle ends)

---

## Phase 5: Reveal

**Function:** `revealProposal(proposalId, decryptionProof, abiEncodedCleartexts)`

Only callable if the proposal was approved (`finalized && resultApproved`). Decrypts all encrypted calldata chunks so they can be executed.

```
for each chunk:
    FHE.makePubliclyDecryptable(chunk)

FHE.checkSignatures(allHandles, abiEncodedCleartexts, decryptionProof)

revealedChunks = abi.decode(abiEncodedCleartexts) as uint256[]
```

**Privacy tradeoff:** After reveal, the proposal actions are public. This is necessary because `dao.execute()` requires plaintext calldata. The privacy guarantee is that actions remain hidden until the proposal is approved.

---

## Phase 6: Execute

**Function:** `execute(proposalId, allowFailureMap)`

Reconstructs the `Action[]` from revealed chunks and calls `dao.execute()`.

```
// Reassemble bytes from uint256 chunks
for each revealedChunk:
    mstore into encodedActions at offset i*32

// Decode and execute
Action[] actions = abi.decode(encodedActions)
dao.execute(proposalId, actions, allowFailureMap)
```

The `allowFailureMap` is a bitmask where bit `i` being set means action `i` is allowed to fail without reverting the entire batch.

---

## Cancellation

**Function:** `cancel(proposalId, cancelKey)`

Available at any point before execution. The proposer provides the plaintext `cancelKey` whose `keccak256` matches the stored `cancelKeyHash`. This is identity-free — anyone who knows the cancel key can cancel.

```
require(keccak256(cancelKey) == proposal.cancelKeyHash)
proposal.cancelled = true
```

A cancelled proposal cannot be voted on, finalized, revealed, or executed.

---

## Summary Table

| Phase           | Function               | Who Can Call      | What's Revealed                                   |
| --------------- | ---------------------- | ----------------- | ------------------------------------------------- |
| 1. Create       | `createProposal()`     | Anyone            | Proposal exists (not content or proposer)         |
| 2. View         | `viewProposal()`       | Members only      | Someone viewed (not who, with EIP-2771)           |
| 3. Vote/Approve | `vote()` / `approve()` | Anyone            | Someone participated (not who or how)             |
| 4. Finalize     | `finalize()`           | Anyone            | Pass or fail (not tallies)                        |
| 5. Reveal       | `revealProposal()`     | Anyone            | Full proposal actions (targets, values, calldata) |
| 6. Execute      | `execute()`            | Anyone            | Execution results                                 |
| Cancel          | `cancel()`             | Cancel key holder | Proposal was cancelled                            |
