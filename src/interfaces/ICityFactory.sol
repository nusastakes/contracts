// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The parts of the factory that vaults, the yield reserve and the guardian read.
interface ICityFactory {
    function maxFeeBps() external view returns (uint16);

    function platformTreasury() external view returns (address);

    /// @dev Maximum total assets per city vault. Platform-wide safety limit.
    function depositCap() external view returns (uint256);

    function isCity(address vault) external view returns (bool);

    /// @dev True for every adapter clone this factory created.
    function isAdapterClone(address adapter) external view returns (bool);
}
