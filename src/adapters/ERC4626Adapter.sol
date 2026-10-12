// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AdapterBase} from "./AdapterBase.sol";

/// @notice Generic adapter for any ERC-4626 vault whose asset equals the city's asset (for example a Morpho vault).
/// It deliberately does not read `maxWithdraw`/`maxRedeem`: some vaults report 0 there even when withdrawals work.
/// Withdrawn amounts are measured as the change in the vault's balance, not trusted from return values.
contract ERC4626Adapter is AdapterBase {
    using SafeERC20 for IERC20;

    IERC4626 public target;

    error AssetMismatch(address expected, address actual);

    /// @dev params = abi.encode(address target)
    function _init(bytes calldata params) internal override {
        address target_ = abi.decode(params, (address));
        address targetAsset = IERC4626(target_).asset();
        if (targetAsset != asset) revert AssetMismatch(asset, targetAsset);
        target = IERC4626(target_);
    }

    function deposit(uint256 assets) external onlyVault {
        IERC20 token = IERC20(asset);
        token.safeTransferFrom(msg.sender, address(this), assets);
        token.forceApprove(address(target), assets);
        target.deposit(assets, address(this));
        token.forceApprove(address(target), 0);
    }

    /// @dev Asking for the whole position (or more, which rounding on the deposit side can cause: depositing 200 can
    /// leave 199.999999 redeemable) redeems every share instead of calling `withdraw`, which would revert.
    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        uint256 shares = target.balanceOf(address(this));
        if (shares == 0) return 0;
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(vault);
        if (assets >= target.convertToAssets(shares)) {
            target.redeem(shares, vault, address(this));
        } else {
            target.withdraw(assets, vault, address(this));
        }
        withdrawn = token.balanceOf(vault) - before;
    }

    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        uint256 shares = target.balanceOf(address(this));
        if (shares == 0) return 0;
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(vault);
        target.redeem(shares, vault, address(this));
        withdrawn = token.balanceOf(vault) - before;
    }

    function totalAssets() external view returns (uint256) {
        return target.convertToAssets(target.balanceOf(address(this)));
    }
}
