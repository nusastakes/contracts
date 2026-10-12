// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The parts of a city vault that the guardian calls or reads.
interface ICityVault {
    function mayor() external view returns (address);

    function isAdapter(address adapter) external view returns (bool);

    function evacuate(address adapter) external;

    function executeProposal(address from, address to, uint256 amount, bytes32 planHash) external;
}
