// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A place a city vault can park its assets. One clone per city; only that city's vault may call it.
interface IAdapter {
    /// @dev Called once by the factory right after cloning. `params` is platform-defined per implementation.
    function initialize(address vault, address asset, bytes calldata params) external;

    function vault() external view returns (address);

    function asset() external view returns (address);

    /// @dev onlyVault: pulls `assets` from the vault (the vault has approved them) and puts them to work.
    function deposit(uint256 assets) external;

    /// @dev onlyVault: sends up to `assets` back to the vault and returns what was actually sent.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @dev onlyVault: sends everything back to the vault and returns what was actually sent.
    function withdrawAll() external returns (uint256 withdrawn);

    /// @dev Current value of this adapter's position, in asset units.
    function totalAssets() external view returns (uint256);
}
