// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {IDAO} from "./IDAO.sol";
import {ERC2771Context} from "./ERC2771Context.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title DAOUpgradeable
/// @notice UUPS-upgradeable version of the core DAO contract.
/// Supports treasury management, batched action execution, role-based permissions,
/// and contract upgrades via UUPS proxy pattern.
/// Note: DAO does not use FHE directly, so no ZamaEthereumConfig needed.
contract DAOUpgradeable is Initializable, UUPSUpgradeable, IDAO, ERC2771Context {
    bytes32 public constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");
    bytes32 public constant ROOT_PERMISSION_ID = keccak256("ROOT_PERMISSION");
    bytes32 public constant UPGRADE_PERMISSION_ID = keccak256("UPGRADE_PERMISSION");

    event PermissionChanged(bytes32 indexed permissionId);

    mapping(bytes32 => bool) private _permissions;

    modifier auth(bytes32 permissionId) {
        require(
            _permissions[_permissionHash(address(this), _msgSender(), permissionId)],
            "DAO: unauthorized"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC2771Context(address(0)) {
        _disableInitializers();
    }

    /// @notice Initialize the DAO (replaces constructor for proxy deployments)
    /// @param initialOwner Address that receives ROOT_PERMISSION and UPGRADE_PERMISSION
    /// @param trustedForwarder_ EIP-2771 trusted forwarder (address(0) to disable)
    function initialize(address initialOwner, address trustedForwarder_) external initializer {
        require(initialOwner != address(0), "DAO: zero address owner");
        _grant(address(this), initialOwner, ROOT_PERMISSION_ID);
        _grant(address(this), initialOwner, UPGRADE_PERMISSION_ID);
    }

    /// @notice Required by UUPS — only UPGRADE_PERMISSION holders can upgrade
    function _authorizeUpgrade(address newImplementation) internal override auth(UPGRADE_PERMISSION_ID) {}

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

    /// @notice Returns the implementation version (useful for verifying upgrades)
    function version() external pure virtual returns (uint256) {
        return 1;
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
