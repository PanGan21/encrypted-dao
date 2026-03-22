// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {FHE, euint64, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC2771Context} from "./ERC2771Context.sol";

/// @title EncryptedGovernanceToken
/// @notice ERC20-like governance token with encrypted balances, voting power snapshots,
/// delegation, and meta-transaction support.
///
/// Privacy: All balances, allowances, and voting power are encrypted (`euint64`).
/// Only totalSupply is public (needed for quorum calculations).
///
/// Snapshots: Voting power is checkpoint-based. When a voting plugin creates a
/// snapshot, the token records voting power before any subsequent modification.
/// This prevents "vote and dump" attacks — voters' power is locked at proposal
/// creation time, not read at vote time.
///
/// Meta-transactions (EIP-2771): All identity-sensitive operations use _msgSender()
/// so members can interact via a trusted forwarder without revealing their address.
/// Note: Functions accepting raw encrypted handles (euint64 parameters) still require
/// direct calls since FHE.isSenderAllowed checks msg.sender.
contract EncryptedGovernanceToken is ERC2771Context, ZamaEthereumConfig {
    // ──────────────────────────── Events ────────────────────────────

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);
    event Mint(address indexed to, uint64 amount);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event SnapshotCreated(uint256 indexed snapshotId);

    // ──────────────────────────── Types ────────────────────────────

    struct VotingPowerCheckpoint {
        uint256 snapshotId;
        euint64 power;
    }

    // ──────────────────────────── State ────────────────────────────

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint64 public totalSupply;
    address public owner;

    mapping(address => euint64) private _balances;
    mapping(address => mapping(address => euint64)) private _allowances;
    mapping(address => address) public delegates;
    mapping(address => euint64) private _votingPower;
    mapping(address => bool) private _isTokenHolder;

    // ── Snapshot state ──
    uint256 public currentSnapshotId;
    mapping(address => VotingPowerCheckpoint[]) private _vpCheckpoints;
    mapping(address => bool) public isSnapshotCreator;

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier onlyOwner() {
        require(_msgSender() == owner, "Not owner");
        _;
    }

    // ──────────────────────────── Constructor ────────────────────────────

    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param trustedForwarder_ EIP-2771 trusted forwarder (address(0) to disable)
    constructor(
        string memory name_,
        string memory symbol_,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        name = name_;
        symbol = symbol_;
        owner = msg.sender;
    }

    // ──────────────────────────── Snapshot Management ────────────────────────────

    /// @notice Authorize an address to create snapshots (e.g. a voting plugin).
    function setSnapshotCreator(address creator, bool authorized) external onlyOwner {
        isSnapshotCreator[creator] = authorized;
    }

    /// @notice Create a new voting power snapshot. Returns the snapshot ID.
    /// @dev Called by voting plugins at proposal creation time.
    function createSnapshot() external returns (uint256) {
        require(isSnapshotCreator[msg.sender], "Not authorized to snapshot");
        currentSnapshotId++;
        emit SnapshotCreated(currentSnapshotId);
        return currentSnapshotId;
    }

    /// @notice Get voting power at a specific snapshot.
    /// @dev Returns the power recorded at the latest checkpoint at or before snapshotId.
    /// If no checkpoint exists, returns current power (account was never modified).
    /// Grants transient ACL access to msg.sender (the calling plugin contract).
    function getSnapshotVotingPower(uint256 snapshotId, address account) external returns (euint64) {
        require(snapshotId > 0 && snapshotId <= currentSnapshotId, "Invalid snapshot");

        VotingPowerCheckpoint[] storage ckpts = _vpCheckpoints[account];

        // Search backwards for the latest checkpoint at or before snapshotId
        for (uint256 i = ckpts.length; i > 0; i--) {
            if (ckpts[i - 1].snapshotId <= snapshotId) {
                euint64 snapshotPower = ckpts[i - 1].power;
                FHE.allowTransient(snapshotPower, msg.sender);
                return snapshotPower;
            }
        }

        // No checkpoint: account was never modified after any snapshot was created.
        // Current power is the correct historical value for all past snapshots.
        euint64 currentPower = _votingPower[account];
        FHE.allowTransient(currentPower, msg.sender);
        return currentPower;
    }

    // ──────────────────────────── Minting ────────────────────────────

    function mint(address to, uint64 amount) external onlyOwner {
        require(to != address(0), "Mint to zero address");

        _isTokenHolder[to] = true;
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);

        address mintDelegate = _getDelegate(to);
        _snapshotVotingPower(mintDelegate);
        _votingPower[mintDelegate] = FHE.add(_votingPower[mintDelegate], amount);
        FHE.allowThis(_votingPower[mintDelegate]);
        FHE.allow(_votingPower[mintDelegate], mintDelegate);

        totalSupply += amount;
        emit Mint(to, amount);
    }

    // ──────────────────────────── Token Holder Registry ────────────────────────────

    function isTokenHolder(address account) external view returns (bool) {
        return _isTokenHolder[account];
    }

    // ──────────────────────────── ERC20 Core ────────────────────────────

    function balanceOf(address account) public view returns (euint64) {
        return _balances[account];
    }

    /// @notice Transfer (encrypted amount from external input) — meta-tx compatible
    function transfer(
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        ebool canTransfer = FHE.le(amount, _balances[_msgSender()]);
        _transfer(_msgSender(), to, amount, canTransfer);
        return true;
    }

    /// @notice Transfer (raw handle) — NOT meta-tx compatible (FHE.isSenderAllowed checks msg.sender)
    function transfer(address to, euint64 amount) public returns (bool) {
        require(FHE.isSenderAllowed(amount));
        ebool canTransfer = FHE.le(amount, _balances[msg.sender]);
        _transfer(msg.sender, to, amount, canTransfer);
        return true;
    }

    /// @notice Approve (encrypted amount from external input) — meta-tx compatible
    function approve(
        address spender,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _approve(_msgSender(), spender, amount);
        emit Approval(_msgSender(), spender);
        return true;
    }

    /// @notice Approve (raw handle) — NOT meta-tx compatible
    function approve(address spender, euint64 amount) public returns (bool) {
        require(FHE.isSenderAllowed(amount));
        _approve(msg.sender, spender, amount);
        emit Approval(msg.sender, spender);
        return true;
    }

    function allowance(address tokenOwner, address spender) public view returns (euint64) {
        return _allowances[tokenOwner][spender];
    }

    /// @notice TransferFrom (encrypted amount) — meta-tx compatible
    function transferFrom(
        address from,
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        ebool isTransferable = _updateAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount, isTransferable);
        return true;
    }

    /// @notice TransferFrom (raw handle) — NOT meta-tx compatible
    function transferFrom(address from, address to, euint64 amount) public returns (bool) {
        require(FHE.isSenderAllowed(amount));
        ebool isTransferable = _updateAllowance(from, msg.sender, amount);
        _transfer(from, to, amount, isTransferable);
        return true;
    }

    // ──────────────────────────── Voting Power (current) ────────────────────────────

    /// @notice Get current voting power (for non-snapshot queries).
    function getVotingPower(address account) external returns (euint64) {
        euint64 power = _votingPower[account];
        FHE.allowTransient(power, msg.sender);
        return power;
    }

    // ──────────────────────────── Delegation ────────────────────────────

    function delegate(address delegatee) external {
        address sender = _msgSender();
        if (delegatee == address(0)) {
            delegatee = sender;
        }

        address currentDelegate = _getDelegate(sender);
        if (currentDelegate == delegatee) return;

        euint64 voterBalance = _balances[sender];

        // Snapshot both delegates before modification
        _snapshotVotingPower(currentDelegate);
        _snapshotVotingPower(delegatee);

        _votingPower[currentDelegate] = FHE.sub(_votingPower[currentDelegate], voterBalance);
        FHE.allowThis(_votingPower[currentDelegate]);
        FHE.allow(_votingPower[currentDelegate], currentDelegate);

        _votingPower[delegatee] = FHE.add(_votingPower[delegatee], voterBalance);
        FHE.allowThis(_votingPower[delegatee]);
        FHE.allow(_votingPower[delegatee], delegatee);

        emit DelegateChanged(sender, currentDelegate, delegatee);
        delegates[sender] = delegatee;
    }

    // ──────────────────────────── Internal ────────────────────────────

    function _getDelegate(address account) internal view returns (address) {
        address d = delegates[account];
        return d == address(0) ? account : d;
    }

    /// @dev Snapshot voting power for `account` before modification.
    /// Records the current (pre-change) power at the current snapshot ID.
    /// Only records once per snapshot ID per account (first write wins).
    function _snapshotVotingPower(address account) internal {
        if (currentSnapshotId == 0) return;

        VotingPowerCheckpoint[] storage ckpts = _vpCheckpoints[account];
        if (ckpts.length == 0 || ckpts[ckpts.length - 1].snapshotId < currentSnapshotId) {
            ckpts.push(VotingPowerCheckpoint({
                snapshotId: currentSnapshotId,
                power: _votingPower[account]
            }));
        }
    }

    function _transfer(
        address from,
        address to,
        euint64 amount,
        ebool isTransferable
    ) internal {
        euint64 transferValue = FHE.select(isTransferable, amount, FHE.asEuint64(0));

        _isTokenHolder[to] = true;

        euint64 newBalanceTo = FHE.add(_balances[to], transferValue);
        _balances[to] = newBalanceTo;
        FHE.allowThis(newBalanceTo);
        FHE.allow(newBalanceTo, to);

        euint64 newBalanceFrom = FHE.sub(_balances[from], transferValue);
        _balances[from] = newBalanceFrom;
        FHE.allowThis(newBalanceFrom);
        FHE.allow(newBalanceFrom, from);

        // Snapshot both delegates before modifying voting power
        address fromDelegate = _getDelegate(from);
        address toDelegate = _getDelegate(to);

        _snapshotVotingPower(fromDelegate);
        _snapshotVotingPower(toDelegate);

        _votingPower[fromDelegate] = FHE.sub(_votingPower[fromDelegate], transferValue);
        FHE.allowThis(_votingPower[fromDelegate]);
        FHE.allow(_votingPower[fromDelegate], fromDelegate);

        _votingPower[toDelegate] = FHE.add(_votingPower[toDelegate], transferValue);
        FHE.allowThis(_votingPower[toDelegate]);
        FHE.allow(_votingPower[toDelegate], toDelegate);

        emit Transfer(from, to);
    }

    function _approve(address tokenOwner, address spender, euint64 amount) internal {
        _allowances[tokenOwner][spender] = amount;
        FHE.allowThis(amount);
        FHE.allow(amount, tokenOwner);
        FHE.allow(amount, spender);
    }

    function _updateAllowance(
        address tokenOwner,
        address spender,
        euint64 amount
    ) internal returns (ebool) {
        euint64 currentAllowance = _allowances[tokenOwner][spender];
        ebool allowedTransfer = FHE.le(amount, currentAllowance);
        ebool canTransfer = FHE.le(amount, _balances[tokenOwner]);
        ebool isTransferable = FHE.and(canTransfer, allowedTransfer);
        _approve(
            tokenOwner,
            spender,
            FHE.select(isTransferable, FHE.sub(currentAllowance, amount), currentAllowance)
        );
        return isTransferable;
    }
}
