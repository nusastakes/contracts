// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AdapterBase} from "../../src/adapters/AdapterBase.sol";
import {MockERC20Permit} from "./MockERC20Permit.sol";

/// @notice Test-only adapter. Holds the assets itself; tests create yield with `addYield` and losses with `lose`.
contract MockYieldAdapter is AdapterBase {
    using SafeERC20 for IERC20;

    address internal constant BURN = address(0xdead);

    function _init(bytes calldata) internal override {}

    function deposit(uint256 assets) external onlyVault {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        withdrawn = assets < balance ? assets : balance;
        IERC20(asset).safeTransfer(vault, withdrawn);
    }

    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        withdrawn = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(vault, withdrawn);
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function addYield(uint256 amount) external {
        MockERC20Permit(asset).mint(address(this), amount);
    }

    function lose(uint256 amount) external {
        IERC20(asset).safeTransfer(BURN, amount);
    }
}
