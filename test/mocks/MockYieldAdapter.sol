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

    /// @dev When set, `withdraw` and `withdrawAll` revert while `totalAssets()` still works (a paused or illiquid protocol).
    bool public failWithdraw;

    function setFailWithdraw(bool value) external {
        failWithdraw = value;
    }

    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        require(!failWithdraw, "withdraw paused");
        uint256 balance = IERC20(asset).balanceOf(address(this));
        withdrawn = assets < balance ? assets : balance;
        IERC20(asset).safeTransfer(vault, withdrawn);
    }

    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        require(!failWithdraw, "withdraw paused");
        withdrawn = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(vault, withdrawn);
    }

    /// @dev 0 = works, 1 = reverts, 2 = returns one byte (not a word), 3 = burns all the gas it is given,
    /// 4 = works but costs a little over two million gas (more than the old 1M probe, less than the 3M probe).
    uint8 public mode;

    function setMode(uint8 newMode) external {
        mode = newMode;
    }

    function totalAssets() external view returns (uint256) {
        if (mode == 1) revert("adapter broken");
        if (mode == 2) {
            assembly {
                mstore(0, 1)
                return(0, 1)
            }
        }
        if (mode == 3) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (mode == 4) {
            assembly {
                for { let i := 0 } lt(i, 36000) { i := add(i, 1) } { mstore(0x40, i) }
            }
        }
        return IERC20(asset).balanceOf(address(this));
    }

    function addYield(uint256 amount) external {
        MockERC20Permit(asset).mint(address(this), amount);
    }

    function lose(uint256 amount) external {
        IERC20(asset).safeTransfer(BURN, amount);
    }
}
