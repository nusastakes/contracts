// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";

/// @notice Shared setup for adapters that are deployed as EIP-1167 clones. The implementation itself is locked so
/// nobody can initialise it; each clone is initialised once, atomically, by the factory.
abstract contract AdapterBase is IAdapter {
    address public vault;
    address public asset;
    bool private _initialized;

    error NotVault();
    error AlreadyInitialized();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor() {
        _initialized = true;
    }

    function initialize(address vault_, address asset_, bytes calldata params) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        vault = vault_;
        asset = asset_;
        _init(params);
    }

    /// @dev Implementation-specific setup; `vault` and `asset` are already set.
    function _init(bytes calldata params) internal virtual;
}
