// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

/// @title ERC2771Context
/// @notice Minimal EIP-2771 meta-transaction support.
/// When msg.sender is the trusted forwarder, the real sender is extracted from the
/// last 20 bytes of calldata. This hides the caller's identity on-chain — observers
/// see only the forwarder's address in transaction logs.
abstract contract ERC2771Context {
    address private immutable _trustedForwarder;

    constructor(address trustedForwarder_) {
        _trustedForwarder = trustedForwarder_;
    }

    function trustedForwarder() public view returns (address) {
        return _trustedForwarder;
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    /// @dev Returns the real sender: extracted from calldata if forwarded, else msg.sender.
    function _msgSender() internal view returns (address sender) {
        if (msg.sender == _trustedForwarder && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /// @dev Returns msg.data without the appended sender (if forwarded).
    function _msgData() internal view returns (bytes calldata) {
        if (msg.sender == _trustedForwarder && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        }
        return msg.data;
    }
}
