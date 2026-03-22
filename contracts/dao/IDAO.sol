// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

/// @title IDAO
/// @notice Interface for the core DAO contract, inspired by Aragon's DAO architecture.
/// The DAO acts as a treasury and executor — plugins (voting, multisig) are granted
/// EXECUTE_PERMISSION to call execute() after governance approval.
interface IDAO {
    /// @notice A single action the DAO can execute
    /// @param to Target contract address
    /// @param value ETH value to send
    /// @param data Calldata for the target call
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Emitted when a set of actions is executed
    /// @param callId Unique identifier for this execution batch
    /// @param actor The address that triggered execution
    /// @param actions The actions that were executed
    /// @param allowFailureMap Bitmask of actions allowed to fail
    /// @param failureMap Bitmask of actions that actually failed
    event Executed(
        bytes32 indexed callId,
        address indexed actor,
        Action[] actions,
        uint256 allowFailureMap,
        uint256 failureMap
    );

    /// @notice Emitted when ETH is deposited into the DAO
    event ETHDeposited(address indexed sender, uint256 amount);

    /// @notice Execute a batch of actions.
    /// @dev Only callable by addresses with EXECUTE_PERMISSION on the DAO.
    /// @param callId A unique identifier for this batch (e.g. proposal ID)
    /// @param actions Array of actions to execute sequentially
    /// @param allowFailureMap Bitmask where bit i = 1 means action[i] is allowed to fail
    /// @return results Array of return data from each action
    /// @return failureMap Bitmask of actions that failed (subset of allowFailureMap)
    function execute(
        bytes32 callId,
        Action[] calldata actions,
        uint256 allowFailureMap
    ) external returns (bytes[] memory results, uint256 failureMap);

    /// @notice Check if an address has a specific permission
    /// @param where The contract address where the permission applies
    /// @param who The address to check
    /// @param permissionId The permission identifier
    /// @return True if the address has the permission
    function hasPermission(address where, address who, bytes32 permissionId) external view returns (bool);
}
