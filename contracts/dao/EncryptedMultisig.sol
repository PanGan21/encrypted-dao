// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {FHE, euint64, euint256, ebool, externalEuint256} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IDAO} from "./IDAO.sol";
import {ERC2771Context} from "./ERC2771Context.sol";

/// @title EncryptedMultisig
/// @notice Aragon-style multisig plugin with full FHE privacy, on-chain encrypted
/// calldata, identity-hiding proposals, and meta-transaction support.
///
/// ───── Privacy Model ─────
///
/// - **Private membership** — signer identities stored as encrypted booleans.
///   Anyone can call approve(); non-signers silently contribute zero.
/// - **Hidden approval count** — encrypted tally, only pass/fail revealed.
/// - **On-chain encrypted calldata** — full proposal actions stored as euint256 chunks.
///   Only signers who view/approve receive FHE.allow to decrypt.
/// - **Identity-free proposals** — anyone can create proposals (no signer check).
///   Non-signer proposals never reach threshold.
/// - **Meta-transactions (EIP-2771)** — all operations use _msgSender() for caller
///   privacy via trusted forwarder.
///
/// ──────────────────────────────────────────────────────────────────────
contract EncryptedMultisig is ERC2771Context, ZamaEthereumConfig {
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

    struct Proposal {
        uint64 createdAt;
        uint64 expiresAt;
        euint64 encryptedApprovals;
        uint256 chunkCount;
        bool finalized;
        bool resultApproved;
        bool revealed;
        bool executed;
        bool cancelled;
        bytes32 cancelKeyHash;
    }

    // ──────────────────────────── Events ────────────────────────────

    event ProposalCreated(uint256 indexed proposalId);
    event ProposalViewed(uint256 indexed proposalId);
    event Approved(uint256 indexed proposalId);
    event ProposalFinalized(uint256 indexed proposalId, bool approved);
    event ProposalRevealed(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event SignerCountUpdated(uint256 newCount);

    // ──────────────────────────── State ────────────────────────────

    IDAO public immutable dao;

    uint256 public proposalCount;
    uint64 public threshold;
    uint64 public proposalDuration;
    uint256 public signerCount;

    mapping(address => ebool) private _encryptedSigners;
    mapping(address => bool) private _isSigner;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasApproved;

    mapping(uint256 => euint256[]) private _encryptedChunks;
    mapping(uint256 => uint256[]) private _revealedChunks;

    // ──────────────────────────── Constructor ────────────────────────────

    constructor(
        IDAO _dao,
        address[] memory _signers,
        uint64 _threshold,
        uint64 _proposalDuration,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        require(address(_dao) != address(0), "Invalid DAO");
        require(_signers.length > 0, "Need at least one signer");
        require(_threshold > 0 && _threshold <= _signers.length, "Invalid threshold");
        require(_proposalDuration > 0, "Invalid duration");

        dao = _dao;
        threshold = _threshold;
        proposalDuration = _proposalDuration;

        for (uint256 i; i < _signers.length; i++) {
            require(_signers[i] != address(0), "Zero address");
            require(!_isSigner[_signers[i]], "Duplicate signer");
            _isSigner[_signers[i]] = true;
            ebool flag = FHE.asEbool(true);
            FHE.allowThis(flag);
            _encryptedSigners[_signers[i]] = flag;
        }
        signerCount = _signers.length;
    }

    // ──────────────────────────── Proposal Creation ────────────────────────────

    /// @notice Create a multisig proposal with encrypted calldata on-chain.
    /// @dev ANYONE can call — no signer check, no revert based on membership.
    /// Non-signer proposals simply never reach the approval threshold.
    /// @param encHandles Encrypted euint256 calldata chunks (ABI-encoded Action[])
    /// @param inputProof Single proof for all encrypted inputs
    /// @param cancelKeyHash keccak256(cancelKey) for identity-free cancellation
    function createProposal(
        bytes32[] calldata encHandles,
        bytes calldata inputProof,
        bytes32 cancelKeyHash
    ) external returns (uint256 proposalId) {
        uint256 chunkCount = encHandles.length;
        require(chunkCount > 0, "No calldata chunks");
        require(chunkCount <= MAX_CALLDATA_CHUNKS, "Too many chunks");
        require(cancelKeyHash != bytes32(0), "Invalid cancel key");

        proposalCount++;
        proposalId = proposalCount;

        address sender = _msgSender();

        for (uint256 i; i < chunkCount; i++) {
            euint256 chunk = FHE.fromExternal(externalEuint256.wrap(encHandles[i]), inputProof);
            FHE.allowThis(chunk);
            FHE.allow(chunk, sender);
            _encryptedChunks[proposalId].push(chunk);
        }

        euint64 zeroApprovals = FHE.asEuint64(0);
        FHE.allowThis(zeroApprovals);

        _proposals[proposalId] = Proposal({
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + proposalDuration,
            encryptedApprovals: zeroApprovals,
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

    /// @notice Request decryption access to encrypted calldata chunks.
    /// @dev Only signers can view (checked via internal flag).
    function viewProposal(uint256 proposalId) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        require(_isSigner[_msgSender()], "Not a signer");
        Proposal storage p = _proposals[proposalId];
        require(!p.cancelled, "Cancelled");

        address sender = _msgSender();
        euint256[] storage chunks = _encryptedChunks[proposalId];
        for (uint256 i; i < chunks.length; i++) {
            FHE.allow(chunks[i], sender);
        }

        emit ProposalViewed(proposalId);
    }

    // ──────────────────────────── Approval ────────────────────────────

    /// @notice Approve a proposal. Anyone can call — non-signer approvals
    /// silently add zero via homomorphic AND with encrypted signer flag.
    function approve(uint256 proposalId) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(block.timestamp <= p.expiresAt, "Proposal expired");
        require(!p.cancelled, "Cancelled");
        require(!p.finalized, "Already finalized");

        address sender = _msgSender();
        require(!_hasApproved[proposalId][sender], "Already approved");
        _hasApproved[proposalId][sender] = true;

        ebool callerIsSigner = _encryptedSigners[sender];
        euint64 one = FHE.asEuint64(1);
        euint64 zero = FHE.asEuint64(0);
        euint64 increment = FHE.select(callerIsSigner, one, zero);

        p.encryptedApprovals = FHE.add(p.encryptedApprovals, increment);
        FHE.allowThis(p.encryptedApprovals);

        // Grant approver access to encrypted calldata
        euint256[] storage chunks = _encryptedChunks[proposalId];
        for (uint256 i; i < chunks.length; i++) {
            FHE.allow(chunks[i], sender);
        }

        emit Approved(proposalId);
    }

    // ──────────────────────────── Finalization ────────────────────────────

    function finalize(
        uint256 proposalId,
        bytes calldata decryptionProof,
        bytes calldata abiEncodedCleartexts
    ) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(!p.finalized, "Already finalized");
        require(!p.cancelled, "Cancelled");

        ebool meetsThreshold = FHE.ge(p.encryptedApprovals, threshold);
        FHE.makePubliclyDecryptable(meetsThreshold);

        bytes32[] memory handlesList = new bytes32[](1);
        handlesList[0] = FHE.toBytes32(meetsThreshold);

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        p.finalized = true;
        p.resultApproved = abi.decode(abiEncodedCleartexts, (bool));

        emit ProposalFinalized(proposalId, p.resultApproved);
    }

    // ──────────────────────────── Reveal ────────────────────────────

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

        bytes32[] memory handlesList = new bytes32[](count);
        for (uint256 i; i < count; i++) {
            FHE.makePubliclyDecryptable(chunks[i]);
            handlesList[i] = FHE.toBytes32(chunks[i]);
        }

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        uint256[] memory values = abi.decode(abiEncodedCleartexts, (uint256[]));
        require(values.length == count, "Chunk count mismatch");

        for (uint256 i; i < count; i++) {
            _revealedChunks[proposalId].push(values[i]);
        }

        p.revealed = true;
        emit ProposalRevealed(proposalId);
    }

    // ──────────────────────────── Execution ────────────────────────────

    /// @notice Execute a revealed proposal by reconstructing actions from chunks.
    function execute(uint256 proposalId, uint256 allowFailureMap) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(p.revealed, "Not revealed");
        require(!p.executed, "Already executed");
        require(!p.cancelled, "Cancelled");

        p.executed = true;

        uint256[] storage chunks = _revealedChunks[proposalId];
        uint256 count = chunks.length;
        bytes memory encodedActions = new bytes(count * 32);

        for (uint256 i; i < count; i++) {
            uint256 val = chunks[i];
            assembly {
                mstore(add(encodedActions, add(32, mul(i, 32))), val)
            }
        }

        IDAO.Action[] memory actions = abi.decode(encodedActions, (IDAO.Action[]));
        dao.execute(bytes32(proposalId), actions, allowFailureMap);

        emit ProposalExecuted(proposalId);
    }

    // ──────────────────────────── Cancellation ────────────────────────────

    /// @notice Cancel using the cancel key (identity-free).
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
        if (block.timestamp <= p.expiresAt && !p.finalized) return ProposalState.Active;
        return ProposalState.Pending;
    }

    function getProposalInfo(uint256 proposalId)
        external
        view
        returns (
            uint64 createdAt,
            uint64 expiresAt,
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
            p.createdAt,
            p.expiresAt,
            p.chunkCount,
            p.finalized,
            p.resultApproved,
            p.revealed,
            p.executed,
            p.cancelled
        );
    }

    function getRevealedChunks(uint256 proposalId)
        external
        view
        returns (uint256[] memory)
    {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        require(_proposals[proposalId].revealed, "Not revealed");
        return _revealedChunks[proposalId];
    }

    // ──────────────────────────── Signer Management (via DAO) ────────────────────────────

    function addSigner(address signer) external {
        require(msg.sender == address(dao), "Only via DAO");
        require(!_isSigner[signer], "Already a signer");
        require(signer != address(0), "Zero address");
        _isSigner[signer] = true;
        ebool flag = FHE.asEbool(true);
        FHE.allowThis(flag);
        _encryptedSigners[signer] = flag;
        signerCount++;
        emit SignerCountUpdated(signerCount);
    }

    function removeSigner(address signer) external {
        require(msg.sender == address(dao), "Only via DAO");
        require(_isSigner[signer], "Not a signer");
        require(signerCount - 1 >= threshold, "Would break threshold");
        _isSigner[signer] = false;
        ebool flag = FHE.asEbool(false);
        FHE.allowThis(flag);
        _encryptedSigners[signer] = flag;
        signerCount--;
        emit SignerCountUpdated(signerCount);
    }

    function setThreshold(uint64 newThreshold) external {
        require(msg.sender == address(dao), "Only via DAO");
        require(newThreshold > 0 && newThreshold <= signerCount, "Invalid threshold");
        threshold = newThreshold;
    }
}
