// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IDAO} from "./IDAO.sol";
import {ERC2771Context} from "./ERC2771Context.sol";

/// @title DAO
/// @notice Core DAO contract: treasury, batched action execution, role-based permissions.
/// Supports EIP-2771 meta-transactions so callers can interact via a trusted forwarder
/// without revealing their address on-chain.
contract DAO is IDAO, ERC2771Context, ZamaEthereumConfig {
    bytes32 public constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");
    bytes32 public constant ROOT_PERMISSION_ID = keccak256("ROOT_PERMISSION");

    event PermissionChanged(bytes32 indexed permissionId);

    mapping(bytes32 => bool) private _permissions;

    modifier auth(bytes32 permissionId) {
        require(
            _permissions[_permissionHash(address(this), _msgSender(), permissionId)],
            "DAO: unauthorized"
        );
        _;
    }

    /// @param initialOwner Address that receives ROOT_PERMISSION
    /// @param trustedForwarder_ EIP-2771 trusted forwarder (address(0) to disable)
    constructor(address initialOwner, address trustedForwarder_) ERC2771Context(trustedForwarder_) {
        require(initialOwner != address(0), "DAO: zero address owner");
        _grant(address(this), initialOwner, ROOT_PERMISSION_ID);
    }

    /// @inheritdoc IDAO
    function execute(
        bytes32 callId,
        Action[] calldata actions,
        uint256 allowFailureMap
    ) external override auth(EXECUTE_PERMISSION_ID) returns (bytes[] memory results, uint256 failureMap) {
        require(actions.length > 0, "DAO: no actions");
        require(actions.length <= 256, "DAO: too many actions");

        results = new bytes[](actions.length);

        for (uint256 i; i < actions.length; ) {
            (bool success, bytes memory result) = actions[i].to.call{value: actions[i].value}(
                actions[i].data
            );

            if (!success) {
                if (allowFailureMap & (1 << i) != 0) {
                    failureMap |= (1 << i);
                } else {
                    if (result.length > 0) {
                        assembly {
                            revert(add(result, 0x20), mload(result))
                        }
                    }
                    revert("DAO: action failed");
                }
            }

            results[i] = result;
            unchecked { i++; }
        }

        emit Executed(callId, _msgSender(), actions, allowFailureMap, failureMap);
    }

    function grant(address where, address who, bytes32 permissionId) external auth(ROOT_PERMISSION_ID) {
        _grant(where, who, permissionId);
    }

    function revoke(address where, address who, bytes32 permissionId) external auth(ROOT_PERMISSION_ID) {
        _revoke(where, who, permissionId);
    }

    /// @inheritdoc IDAO
    function hasPermission(address where, address who, bytes32 permissionId) external view override returns (bool) {
        return _permissions[_permissionHash(where, who, permissionId)];
    }

    function _grant(address where, address who, bytes32 permissionId) internal {
        bytes32 hash = _permissionHash(where, who, permissionId);
        if (!_permissions[hash]) {
            _permissions[hash] = true;
            emit PermissionChanged(permissionId);
        }
    }

    function _revoke(address where, address who, bytes32 permissionId) internal {
        bytes32 hash = _permissionHash(where, who, permissionId);
        if (_permissions[hash]) {
            _permissions[hash] = false;
            emit PermissionChanged(permissionId);
        }
    }

    function _permissionHash(address where, address who, bytes32 permissionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(where, who, permissionId));
    }

    receive() external payable { emit ETHDeposited(msg.sender, msg.value); }
    fallback() external payable { emit ETHDeposited(msg.sender, msg.value); }
}
