// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {FHE, euint64, euint256, ebool, externalEbool, externalEuint256} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IDAO} from "./IDAO.sol";
import {EncryptedGovernanceToken} from "./EncryptedGovernanceToken.sol";
import {ERC2771Context} from "./ERC2771Context.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title EncryptedTokenVoting
/// @notice UUPS-upgradeable token voting plugin with full FHE privacy.
contract EncryptedTokenVoting is Initializable, UUPSUpgradeable, ERC2771Context {
    // ──────────────────────────── Constants ────────────────────────────

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
        uint64 startDate;
        uint64 endDate;
    }

    struct Proposal {
        uint256 snapshotId;
        uint64 voteStart;
        uint64 voteEnd;
        euint64 encryptedForVotes;
        euint64 encryptedAgainstVotes;
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
    event VoteCast(uint256 indexed proposalId);
    event ProposalFinalized(uint256 indexed proposalId, bool approved);
    event ProposalRevealed(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);

    // ──────────────────────────── State ────────────────────────────

    IDAO public dao;
    EncryptedGovernanceToken public governanceToken;

    uint256 public proposalCount;
    uint64 public votingDuration;
    uint64 public minQuorumPct;
    uint64 public minSupportPct;
    uint64 public minProposerBalance;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;
    mapping(uint256 => euint256[]) private _encryptedChunks;
    mapping(uint256 => uint256[]) private _revealedChunks;

    // ──────────────────────────── Constructor & Initializer ────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC2771Context(address(0)) {
        _disableInitializers();
    }

    function initialize(
        IDAO _dao,
        EncryptedGovernanceToken _token,
        uint64 _votingDuration,
        uint64 _minQuorumPct,
        uint64 _minSupportPct,
        uint64 _minProposerBalance,
        address
    ) external initializer {
        require(address(_dao) != address(0), "Invalid DAO");
        require(address(_token) != address(0), "Invalid token");
        require(_votingDuration > 0, "Invalid voting duration");
        require(_minQuorumPct > 0 && _minQuorumPct <= 100, "Invalid quorum");
        require(_minSupportPct > 0 && _minSupportPct <= 100, "Invalid support");

        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());

        dao = _dao;
        governanceToken = _token;
        votingDuration = _votingDuration;
        minQuorumPct = _minQuorumPct;
        minSupportPct = _minSupportPct;
        minProposerBalance = _minProposerBalance;
    }

    /// @notice Required by UUPS — only DAO can authorize upgrades
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == address(dao), "Only via DAO");
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    // ──────────────────────────── Proposal Creation ────────────────────────────

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

        for (uint256 i; i < chunkCount; i++) {
            euint256 chunk = FHE.fromExternal(externalEuint256.wrap(encHandles[i]), inputProof);
            FHE.allowThis(chunk);
            FHE.allow(chunk, sender);
            _encryptedChunks[proposalId].push(chunk);
        }

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

    function vote(uint256 proposalId, externalEbool encryptedVote, bytes calldata inputProof) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        Proposal storage p = _proposals[proposalId];
        require(block.timestamp >= p.voteStart && block.timestamp <= p.voteEnd, "Voting not active");
        require(!p.cancelled, "Proposal cancelled");

        address sender = _msgSender();
        require(!_hasVoted[proposalId][sender], "Already voted");
        _hasVoted[proposalId][sender] = true;

        ebool voteChoice = FHE.fromExternal(encryptedVote, inputProof);

        euint64 voterWeight = governanceToken.getSnapshotVotingPower(p.snapshotId, sender);
        euint64 zero = FHE.asEuint64(0);

        euint64 forWeight = FHE.select(voteChoice, voterWeight, zero);
        euint64 againstWeight = FHE.select(voteChoice, zero, voterWeight);

        p.encryptedForVotes = FHE.add(p.encryptedForVotes, forWeight);
        p.encryptedAgainstVotes = FHE.add(p.encryptedAgainstVotes, againstWeight);

        FHE.allowThis(p.encryptedForVotes);
        FHE.allowThis(p.encryptedAgainstVotes);

        euint256[] storage chunks = _encryptedChunks[proposalId];
        for (uint256 i; i < chunks.length; i++) {
            FHE.allow(chunks[i], sender);
        }

        emit VoteCast(proposalId);
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

    function getRevealedChunks(uint256 proposalId) external view returns (uint256[] memory) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        require(_proposals[proposalId].revealed, "Not revealed");
        return _revealedChunks[proposalId];
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _hasVoted[proposalId][voter];
    }
}
