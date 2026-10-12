// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A reserve that enrolls adapters and promises a huge budget but whose `pay` always reverts, as if the token
/// had frozen it. Used to prove a failing reserve cannot trap an adapter's principal.
contract MockBrokenReserve {
    function enroll() external pure returns (uint256) {
        return type(uint128).max;
    }

    function quotaOf(address) external pure returns (uint256) {
        return type(uint128).max;
    }

    function pay(address, uint256) external pure returns (uint256) {
        revert("reserve frozen");
    }
}
