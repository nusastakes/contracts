// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Plain ERC-4626 vault used as the target of `ERC4626Adapter` in unit tests. Like Morpho Vault V2 (reported
/// by the S26 spike), it can be switched to report 0 from the `max*` functions while deposits and withdrawals still
/// work, to prove the adapter does not rely on them.
contract MockERC4626 is ERC4626 {
    bool public maxFunctionsReturnZero;

    constructor(IERC20 asset_) ERC20("Mock Vault", "mVAULT") ERC4626(asset_) {}

    function setMaxFunctionsReturnZero(bool value) external {
        maxFunctionsReturnZero = value;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return maxFunctionsReturnZero ? 0 : super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return maxFunctionsReturnZero ? 0 : super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return maxFunctionsReturnZero ? 0 : super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return maxFunctionsReturnZero ? 0 : super.maxRedeem(owner);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (!maxFunctionsReturnZero) return super.deposit(assets, receiver);
        shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        if (!maxFunctionsReturnZero) return super.withdraw(assets, receiver, owner);
        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (!maxFunctionsReturnZero) return super.redeem(shares, receiver, owner);
        assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }
}
