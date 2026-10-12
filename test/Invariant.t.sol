// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseTest} from "./Base.t.sol";
import {CityVault} from "../src/CityVault.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

/// @notice Random sequences of deposits, withdrawals, yield, losses, rebalances and fee harvests.
contract VaultHandler is Test {
    CityVault public vault;
    MockERC20Permit public asset;
    MockYieldAdapter public adapterA;
    MockYieldAdapter public adapterB;
    address public mayor;

    address[] public actors;

    // Every asset that enters or leaves the city from outside, in asset units.
    uint256 public ghostIn;
    uint256 public ghostOut;
    uint256 public ghostGain;
    uint256 public ghostLoss;

    constructor(CityVault vault_, MockERC20Permit asset_, MockYieldAdapter a, MockYieldAdapter b, address mayor_) {
        vault = vault_;
        asset = asset_;
        adapterA = a;
        adapterB = b;
        mayor = mayor_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _adapter(uint256 seed) internal view returns (MockYieldAdapter) {
        return seed % 2 == 0 ? adapterA : adapterB;
    }

    function _node(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 3;
        if (pick == 0) return address(0);
        return pick == 1 ? address(adapterA) : address(adapterB);
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1_000_000 * 1e6);
        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();
        ghostIn += amount;
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external {
        address actor = _actor(actorSeed);
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;
        shares = shares * bound(fractionBps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(actor);
        ghostOut += vault.redeem(shares, actor, actor);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        amount = bound(amount, 0, max);
        if (amount == 0) return;
        vm.prank(actor);
        vault.withdraw(amount, actor, actor);
        ghostOut += amount;
    }

    function yieldIn(uint256 adapterSeed, uint256 amount) external {
        amount = bound(amount, 0, 100_000 * 1e6);
        _adapter(adapterSeed).addYield(amount);
        ghostGain += amount;
    }

    function lossOut(uint256 adapterSeed, uint256 amount) external {
        MockYieldAdapter adapter = _adapter(adapterSeed);
        amount = bound(amount, 0, adapter.totalAssets() / 2);
        adapter.lose(amount);
        ghostLoss += amount;
    }

    function rebalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _node(fromSeed);
        address to = _node(toSeed);
        if (from == to) return;
        uint256 total = vault.totalAssets();
        amount = bound(amount, 1, total == 0 ? 1 : total / 2 + 1);
        vm.prank(mayor);
        try vault.rebalance(from, to, amount, bytes32(amount)) {} catch {}
    }

    function harvest() external {
        vault.harvestFee();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 days));
    }
}

contract InvariantTest is BaseTest {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, asset, adapterA, adapterB, mayor);
        targetContract(address(handler));
    }

    function _holders() internal view returns (address[] memory list) {
        uint256 n = handler.actorCount();
        list = new address[](n + 2);
        for (uint256 i; i < n; ++i) {
            list[i] = handler.actors(i);
        }
        list[n] = mayor;
        list[n + 1] = treasury;
    }

    /// @dev Brief 9.6 #10: the sum of everybody's claim never exceeds what the city holds (floor rounding only
    /// ever favours the vault).
    function invariant_ClaimsNeverExceedTotalAssets() public view {
        address[] memory list = _holders();
        uint256 claims;
        for (uint256 i; i < list.length; ++i) {
            claims += vault.convertToAssets(vault.balanceOf(list[i]));
        }
        assertLe(claims, vault.totalAssets(), "claims exceed assets");
    }

    function invariant_TotalAssetsIsIdlePlusAdapters() public view {
        assertEq(
            vault.totalAssets(),
            asset.balanceOf(address(vault)) + adapterA.totalAssets() + adapterB.totalAssets(),
            "accounting drift"
        );
    }

    /// @dev Money only enters and leaves through deposits, withdrawals, and the (simulated) yield and loss of the
    /// adapters. Rebalances and fee mints never create or destroy assets.
    function invariant_AssetsMatchExternalFlows() public view {
        assertEq(
            vault.totalAssets() + handler.ghostOut() + handler.ghostLoss(),
            handler.ghostIn() + handler.ghostGain(),
            "assets appeared or disappeared"
        );
    }

    /// @dev Everybody can always exit completely. What stays behind is bounded by the virtual shares that defend
    /// against the inflation attack (they own 10**6 / (supply + 10**6) of the assets) plus rounding dust.
    function invariant_EveryoneCanExit() public {
        uint256 snap = vm.snapshotState();
        address[] memory list = _holders();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        // Each redemption can crystallise a little fee for the mayor or treasury after they already left, so go
        // around until nobody holds shares. Three passes are plenty: fee only appears from rounding after the first.
        vault.harvestFee();
        for (uint256 pass; pass < 3; ++pass) {
            for (uint256 i; i < list.length; ++i) {
                uint256 shares = vault.balanceOf(list[i]);
                if (shares == 0) continue;
                vm.prank(list[i]);
                vault.redeem(shares, list[i], list[i]);
            }
        }
        assertEq(vault.totalSupply(), 0, "shares left over");
        uint256 virtualShare = (assetsBefore + 1) * 1e6 / (supplyBefore + 1e6);
        assertLe(
            vault.totalAssets(), virtualShare + 2 * list.length + 2, "more than virtual-share and rounding dust left"
        );
        vm.revertToState(snap);
    }
}

contract VaultFuzzTest is BaseTest {
    function testFuzz_DepositRedeemRoundTripWithoutYieldIsExact(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000 * UNIT);
        uint256 shares = _deposit(alice, amount);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), amount);
    }

    function testFuzz_FeeNeverExceedsFeeBpsOfProfit(uint256 deposit, uint256 gain) public {
        deposit = bound(deposit, 1 * UNIT, 1_000_000_000 * UNIT);
        gain = bound(gain, 0, 10 * deposit);
        _deposit(alice, deposit);
        _move(address(0), address(adapterA), deposit / 2);
        adapterA.addYield(gain);
        vault.harvestFee();

        uint256 feeValue = _assetsOf(mayor) + _assetsOf(treasury);
        // 10% of the gain, plus a few units of rounding.
        assertLe(feeValue, gain / 10 + 10, "fee holders took more than 10% of the profit");
        // Virtual shares keep about 1e-6 of the assets, so allow that on top of rounding.
        assertApproxEqAbs(_assetsOf(alice) + feeValue, deposit + gain, 10 + (deposit + gain) / 1e6);
    }

    function testFuzz_FeeNeverTakenFromPrincipalAfterLoss(uint256 deposit, uint256 lossBps, uint256 regain) public {
        deposit = bound(deposit, 10 * UNIT, 1_000_000_000 * UNIT);
        _deposit(alice, deposit);
        _move(address(0), address(adapterA), deposit / 2);

        adapterA.addYield(deposit / 10);
        vault.harvestFee();
        uint256 supplyAtHigh = vault.totalSupply();
        uint256 aliceAtHigh = _assetsOf(alice);

        lossBps = bound(lossBps, 1, 9000);
        uint256 loss = adapterA.totalAssets() * lossBps / 10_000;
        adapterA.lose(loss);
        vault.harvestFee();
        assertEq(vault.totalSupply(), supplyAtHigh, "fee after a loss");

        // Regain at most what was lost: still no fee.
        regain = bound(regain, 0, loss);
        adapterA.addYield(regain);
        vault.harvestFee();
        assertEq(vault.totalSupply(), supplyAtHigh, "fee while merely recovering");
        assertLe(_assetsOf(alice), aliceAtHigh + 10);
    }
}
