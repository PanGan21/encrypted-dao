// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {FHE, euint64, euint256, ebool, externalEbool, externalEuint256} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IDAO} from "./IDAO.sol";
import {EncryptedGovernanceToken} from "./EncryptedGovernanceToken.sol";
import {ERC2771Context} from "./ERC2771Context.sol";

/// @title EncryptedTokenVoting
/// @notice Aragon-style token voting plugin with full FHE privacy, voting power
/// snapshots, on-chain encrypted calldata, identity-hiding proposals, and
/// meta-transaction support.
///
/// ───── Privacy Model ─────
///
/// - **Vote weight is hidden** — derived from snapshotted encrypted token balances.
/// - **Vote direction is hidden** — encrypted booleans, tallied homomorphically.
/// - **Tallies are hidden** — only pass/fail is revealed at finalization.
/// - **Proposal content is on-chain but encrypted** — target, value, and full calldata
///   are stored as encrypted euint256 chunks. Only members who call viewProposal()
///   or vote() receive FHE.allow to decrypt.
/// - **Proposer identity is hidden** — anyone can create proposals. Non-token-holder
///   proposals simply never reach quorum. No revert leaks membership status.
/// - **Caller identity is hidden** — EIP-2771 meta-transactions allow members to
///   interact through a trusted forwarder without revealing their address.
///
/// ───── Lifecycle ─────
///
/// 1. createProposal() — submit encrypted calldata chunks (no identity check)
/// 2. viewProposal()   — token holders decrypt proposal content before voting
/// 3. vote()           — encrypted ballot weighted by snapshotted voting power
/// 4. finalize()       — reveals only pass/fail via KMS
/// 5. revealProposal() — decrypts all chunks for execution
/// 6. execute()        — reconstructs actions from revealed chunks, calls DAO
///
/// ──────────────────────────────────────────────────────────────────────
contract EncryptedTokenVoting is ERC2771Context, ZamaEthereumConfig {
    // ──────────────────────────── Constants ────────────────────────────

    /// @notice Maximum number of 32-byte encrypted calldata chunks per proposal.
    /// 24 chunks = 768 bytes, enough for most governance actions.
    uint256 public constant MAX_CALLDATA_CHUNKS = 24;

    // ──────────────────────────── Types ────────────────────────────

    enum ProposalState {
        Active,
        Pending,
        Succeeded,
        Defeated,
        Revealed,
        Executed,
        Cancelled
    }

    struct ProposalParams {
        uint64 startDate; // 0 = now
        uint64 endDate; // 0 = now + votingDuration
    }

    struct Proposal {
        // Snapshot
        uint256 snapshotId;
        // Timing
        uint64 voteStart;
        uint64 voteEnd;
        // Encrypted tallies (token-weighted)
        euint64 encryptedForVotes;
        euint64 encryptedAgainstVotes;
        // Calldata chunks
        uint256 chunkCount;
        // State
        bool finalized;
        bool resultApproved;
        bool revealed;
        bool executed;
        bool cancelled;
        // Cancellation
        bytes32 cancelKeyHash;
    }

    // ──────────────────────────── Events ────────────────────────────

    event ProposalCreated(uint256 indexed proposalId);
    event ProposalViewed(uint256 indexed proposalId);
    event VoteCast(uint256 indexed proposalId);
    event ProposalFinalized(uint256 indexed proposalId, bool approved);
    event ProposalRevealed(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);

    // ──────────────────────────── State ────────────────────────────

    IDAO public immutable dao;
    EncryptedGovernanceToken public immutable governanceToken;

    uint256 public proposalCount;
    uint64 public votingDuration;
    uint64 public minQuorumPct; // 1-100
    uint64 public minSupportPct; // 1-100
    uint64 public minProposerBalance;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @dev Encrypted calldata chunks per proposal: proposalId => chunk[]
    mapping(uint256 => euint256[]) private _encryptedChunks;

    /// @dev Revealed plaintext chunks per proposal: proposalId => chunk[]
    mapping(uint256 => uint256[]) private _revealedChunks;

    // ──────────────────────────── Constructor ────────────────────────────

    constructor(
        IDAO _dao,
        EncryptedGovernanceToken _token,
        uint64 _votingDuration,
        uint64 _minQuorumPct,
        uint64 _minSupportPct,
        uint64 _minProposerBalance,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        require(address(_dao) != address(0), "Invalid DAO");
        require(address(_token) != address(0), "Invalid token");
        require(_votingDuration > 0, "Invalid voting duration");
        require(_minQuorumPct > 0 && _minQuorumPct <= 100, "Invalid quorum");
        require(_minSupportPct > 0 && _minSupportPct <= 100, "Invalid support");

        dao = _dao;
        governanceToken = _token;
        votingDuration = _votingDuration;
        minQuorumPct = _minQuorumPct;
        minSupportPct = _minSupportPct;
        minProposerBalance = _minProposerBalance;
    }

    // ──────────────────────────── Proposal Creation ────────────────────────────

    /// @notice Create a proposal with encrypted calldata stored on-chain.
    /// @dev ANYONE can call — no identity check, no revert based on membership.
    /// Non-token-holder proposals simply never reach quorum.
    ///
    /// The `encHandles` array contains all encrypted inputs in order:
    ///   encHandles[0..chunkCount-1] = encrypted euint256 calldata chunks
    ///
    /// The chunks are the ABI-encoded `IDAO.Action[]`, split into 32-byte segments.
    /// Client-side: `abi.encode(actions)` → pad to 32-byte boundary → split → encrypt.
    ///
    /// @param encHandles Array of encrypted handles (calldata chunks as bytes32)
    /// @param inputProof Single proof covering all encrypted inputs
    /// @param cancelKeyHash keccak256(cancelKey) — used for cancellation (identity-free)
    /// @param params Optional start/end dates
    /// @return proposalId The new proposal's ID
    function createProposal(
        bytes32[] calldata encHandles,
        bytes calldata inputProof,
        bytes32 cancelKeyHash,
        ProposalParams calldata params
    ) external returns (uint256 proposalId) {
        uint256 chunkCount = encHandles.length;
        require(chunkCount > 0, "No calldata chunks");
        require(chunkCount <= MAX_CALLDATA_CHUNKS, "Too many chunks");
        require(cancelKeyHash != bytes32(0), "Invalid cancel key");

        proposalCount++;
        proposalId = proposalCount;

        address sender = _msgSender();

        // Process encrypted chunks
        for (uint256 i; i < chunkCount; i++) {
            euint256 chunk = FHE.fromExternal(externalEuint256.wrap(encHandles[i]), inputProof);
            FHE.allowThis(chunk);
            FHE.allow(chunk, sender);
            _encryptedChunks[proposalId].push(chunk);
        }

        // Create voting power snapshot
        uint256 snapshotId = governanceToken.createSnapshot();

        euint64 zeroFor = FHE.asEuint64(0);
        euint64 zeroAgainst = FHE.asEuint64(0);
        FHE.allowThis(zeroFor);
        FHE.allowThis(zeroAgainst);

        uint64 start = params.startDate == 0 ? uint64(block.timestamp) : params.startDate;
        uint64 end = params.endDate == 0 ? start + votingDuration : params.endDate;
        require(end > start, "Invalid dates");

        _proposals[proposalId] = Proposal({
            snapshotId: snapshotId,
            voteStart: start,
            voteEnd: end,
            encryptedForVotes: zeroFor,
            encryptedAgainstVotes: zeroAgainst,
            chunkCount: chunkCount,
            finalized: false,
            resultApproved: false,
            revealed: false,
            executed: false,
            cancelled: false,
            cancelKeyHash: cancelKeyHash
        });

        emit ProposalCreated(proposalId);
    }

    // ──────────────────────────── Proposal Viewing ────────────────────────────

    /// @notice Request decryption access to a proposal's encrypted calldata chunks.
    /// @dev Token holders can view before voting. Grants FHE.allow on all chunks.
    function viewProposal(uint256 proposalId) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        require(governanceToken.isTokenHolder(_msgSender()), "Not a token holder");
        Proposal storage p = _proposals[proposalId];
        require(!p.cancelled, "Proposal cancelled");

        address sender = _msgSender();
        euint256[] storage chunks = _encryptedChunks[proposalId];
        for (uint256 i; i < chunks.length; i++) {
            FHE.allow(chunks[i], sender);
        }

        emit ProposalViewed(proposalId);
    }

    // ──────────────────────────── Voting ────────────────────────────

    /// @notice Cast an encrypted, token-weighted vote using snapshotted voting power.
    /// @dev Anyone can call — zero-balance voters contribute zero weight.
    /// Uses voting power snapshotted at proposal creation, preventing "vote and dump".
    function vote(uint256 proposalId, externalEbool encryptedVote, bytes calldata inputProof) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(block.timestamp >= p.voteStart && block.timestamp <= p.voteEnd, "Voting not active");
        require(!p.cancelled, "Proposal cancelled");

        address sender = _msgSender();
        require(!_hasVoted[proposalId][sender], "Already voted");
        _hasVoted[proposalId][sender] = true;

        ebool voteChoice = FHE.fromExternal(encryptedVote, inputProof);

        // Use SNAPSHOTTED voting power (locked at proposal creation)
        euint64 voterWeight = governanceToken.getSnapshotVotingPower(p.snapshotId, sender);
        euint64 zero = FHE.asEuint64(0);

        euint64 forWeight = FHE.select(voteChoice, voterWeight, zero);
        euint64 againstWeight = FHE.select(voteChoice, zero, voterWeight);

        p.encryptedForVotes = FHE.add(p.encryptedForVotes, forWeight);
        p.encryptedAgainstVotes = FHE.add(p.encryptedAgainstVotes, againstWeight);

        FHE.allowThis(p.encryptedForVotes);
        FHE.allowThis(p.encryptedAgainstVotes);

        // Grant voter access to all encrypted chunks
        euint256[] storage chunks = _encryptedChunks[proposalId];
        for (uint256 i; i < chunks.length; i++) {
            FHE.allow(chunks[i], sender);
        }

        emit VoteCast(proposalId);
    }

    // ──────────────────────────── Finalization ────────────────────────────

    /// @notice Finalize: check quorum + majority homomorphically, reveal pass/fail.
    function finalize(
        uint256 proposalId,
        bytes calldata decryptionProof,
        bytes calldata abiEncodedCleartexts
    ) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(!p.finalized, "Already finalized");
        require(!p.cancelled, "Cancelled");
        require(block.timestamp > p.voteEnd, "Voting not ended");

        uint64 supply = governanceToken.totalSupply();
        uint64 quorumThreshold = (supply * minQuorumPct) / 100;

        euint64 totalVotes = FHE.add(p.encryptedForVotes, p.encryptedAgainstVotes);
        ebool meetsQuorum = FHE.ge(totalVotes, quorumThreshold);
        ebool hasMajority = FHE.gt(p.encryptedForVotes, p.encryptedAgainstVotes);
        ebool approved = FHE.and(meetsQuorum, hasMajority);

        FHE.makePubliclyDecryptable(approved);

        bytes32[] memory handlesList = new bytes32[](1);
        handlesList[0] = FHE.toBytes32(approved);

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        p.finalized = true;
        p.resultApproved = abi.decode(abiEncodedCleartexts, (bool));

        emit ProposalFinalized(proposalId, p.resultApproved);
    }

    // ──────────────────────────── Reveal ────────────────────────────

    /// @notice Reveal all encrypted calldata chunks after approval.
    /// Decrypts via KMS and stores plaintext for execution.
    function revealProposal(
        uint256 proposalId,
        bytes calldata decryptionProof,
        bytes calldata abiEncodedCleartexts
    ) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(p.finalized && p.resultApproved, "Not approved");
        require(!p.revealed, "Already revealed");
        require(!p.cancelled, "Cancelled");

        euint256[] storage chunks = _encryptedChunks[proposalId];
        uint256 count = chunks.length;

        // Make all chunks publicly decryptable
        bytes32[] memory handlesList = new bytes32[](count);
        for (uint256 i; i < count; i++) {
            FHE.makePubliclyDecryptable(chunks[i]);
            handlesList[i] = FHE.toBytes32(chunks[i]);
        }

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // Decode all chunk values
        uint256[] memory values = abi.decode(abiEncodedCleartexts, (uint256[]));
        require(values.length == count, "Chunk count mismatch");

        for (uint256 i; i < count; i++) {
            _revealedChunks[proposalId].push(values[i]);
        }

        p.revealed = true;
        emit ProposalRevealed(proposalId);
    }

    // ──────────────────────────── Execution ────────────────────────────

    /// @notice Execute a revealed proposal.
    /// Reconstructs the ABI-encoded actions from revealed chunks and calls DAO.execute().
    function execute(uint256 proposalId, uint256 allowFailureMap) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(p.revealed, "Not revealed");
        require(!p.executed, "Already executed");
        require(!p.cancelled, "Cancelled");

        p.executed = true;

        // Reconstruct bytes from revealed chunks
        uint256[] storage chunks = _revealedChunks[proposalId];
        uint256 count = chunks.length;
        bytes memory encodedActions = new bytes(count * 32);

        for (uint256 i; i < count; i++) {
            uint256 val = chunks[i];
            assembly {
                mstore(add(encodedActions, add(32, mul(i, 32))), val)
            }
        }

        // Decode the ABI-encoded Action[]
        IDAO.Action[] memory actions = abi.decode(encodedActions, (IDAO.Action[]));

        dao.execute(bytes32(proposalId), actions, allowFailureMap);

        emit ProposalExecuted(proposalId);
    }

    // ──────────────────────────── Cancellation ────────────────────────────

    /// @notice Cancel a proposal using the cancel key (identity-free).
    /// @param proposalId The proposal to cancel
    /// @param cancelKey The plaintext key whose keccak256 matches the stored hash
    function cancel(uint256 proposalId, bytes32 cancelKey) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(!p.executed, "Already executed");
        require(!p.cancelled, "Already cancelled");
        require(keccak256(abi.encodePacked(cancelKey)) == p.cancelKeyHash, "Invalid cancel key");

        p.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // ──────────────────────────── View Functions ────────────────────────────

    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];

        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        if (p.revealed) return ProposalState.Revealed;
        if (p.finalized && p.resultApproved) return ProposalState.Succeeded;
        if (p.finalized && !p.resultApproved) return ProposalState.Defeated;
        if (block.timestamp <= p.voteEnd) return ProposalState.Active;
        return ProposalState.Pending;
    }

    function getProposalInfo(
        uint256 proposalId
    )
        external
        view
        returns (
            uint256 snapshotId,
            uint64 voteStart,
            uint64 voteEnd,
            uint256 chunkCount,
            bool finalized,
            bool resultApproved,
            bool revealed,
            bool executed,
            bool cancelled
        )
    {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        return (
            p.snapshotId,
            p.voteStart,
            p.voteEnd,
            p.chunkCount,
            p.finalized,
            p.resultApproved,
            p.revealed,
            p.executed,
            p.cancelled
        );
    }

    /// @notice Get revealed calldata chunks (only after reveal)
    function getRevealedChunks(uint256 proposalId) external view returns (uint256[] memory) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        require(_proposals[proposalId].revealed, "Not revealed");
        return _revealedChunks[proposalId];
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _hasVoted[proposalId][voter];
    }
}
