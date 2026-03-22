// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {DAOUpgradeable} from "./DAOUpgradeable.sol";

/// @title DAOUpgradeableV2
/// @notice Example V2 upgrade of the DAO contract, demonstrating how to add
/// new functionality while preserving existing state and permissions.
contract DAOUpgradeableV2 is DAOUpgradeable {
    /// @notice New permission for pausing the DAO (added in V2)
    bytes32 public constant PAUSE_PERMISSION_ID = keccak256("PAUSE_PERMISSION");

    /// @dev New state variable in V2 — stored after existing storage slots
    bool private _paused;

    event Paused(address account);
    event Unpaused(address account);

    function pause() external auth(PAUSE_PERMISSION_ID) {
        require(!_paused, "DAO: already paused");
        _paused = true;
        emit Paused(_msgSender());
    }

    function unpause() external auth(PAUSE_PERMISSION_ID) {
        require(_paused, "DAO: not paused");
        _paused = false;
        emit Unpaused(_msgSender());
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice Returns V2 to verify upgrade succeeded
    function version() external pure override returns (uint256) {
        return 2;
    }
}
