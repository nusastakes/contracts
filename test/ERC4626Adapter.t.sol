// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {CityVault} from "../src/CityVault.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract ERC4626AdapterTest is BaseTest {
    MockERC4626 internal target;
    ERC4626Adapter internal impl4626;
    CityVault internal city;
    ERC4626Adapter internal adapter;

    function setUp() public override {
        super.setUp();
        target = new MockERC4626(asset);
        impl4626 = new ERC4626Adapter();
        vm.startPrank(owner);
        factory.setAllowedAdapter(address(impl4626), true);
        factory.setAdapterParams(address(impl4626), abi.encode(address(target)));
        vm.stopPrank();

        address[] memory impls = new address[](1);
        impls[0] = address(impl4626);
        vm.prank(mayor);
        city = CityVault(factory.createCity("Morpho-like", "", 1000, impls, ""));
        adapter = ERC4626Adapter(city.adapters()[0]);

        asset.mint(alice, 1000 * UNIT);
        vm.startPrank(alice);
        asset.approve(address(city), type(uint256).max);
        city.deposit(1000 * UNIT, alice);
        vm.stopPrank();
    }

    function _toTarget(uint256 amount) internal {
        vm.prank(mayor);
        city.rebalance(address(0), address(adapter), amount, bytes32(0));
    }

    function test_DepositAndWithdrawThroughTarget() public {
        _toTarget(500 * UNIT);
        assertApproxEqAbs(adapter.totalAssets(), 500 * UNIT, 1);
        assertEq(asset.balanceOf(address(target)), 500 * UNIT);
        assertEq(city.totalAssets() / UNIT, 1000);

        vm.prank(mayor);
        city.rebalance(address(adapter), address(0), 200 * UNIT, bytes32(0));
        assertApproxEqAbs(adapter.totalAssets(), 300 * UNIT, 1);
        assertEq(asset.balanceOf(address(city)), 700 * UNIT);
    }

    function test_YieldInTargetRaisesCityValue() public {
        _toTarget(500 * UNIT);
        asset.mint(address(target), 50 * UNIT); // target vault earns 10%
        assertApproxEqAbs(adapter.totalAssets(), 550 * UNIT, 2);
        assertApproxEqAbs(city.totalAssets(), 1050 * UNIT, 2);
    }

    function test_ResidentRedeemsEverythingIncludingTargetPosition() public {
        _toTarget(500 * UNIT);
        asset.mint(address(target), 50 * UNIT);
        uint256 shares = city.balanceOf(alice);
        vm.prank(alice);
        uint256 out = city.redeem(shares, alice, alice);
        // 1050 total, 10% fee on 50 profit -> alice keeps about 1045.
        assertApproxEqAbs(out, 1045 * UNIT, 5);
        // The 5 AUSD of fee (mayor and platform shares) is still in the city.
        assertApproxEqAbs(city.totalAssets(), 5 * UNIT, 5);
        assertApproxEqAbs(adapter.totalAssets(), 5 * UNIT, 5);
    }

    function test_WorksWhenTargetReportsZeroFromMaxFunctions() public {
        target.setMaxFunctionsReturnZero(true);
        assertEq(target.maxWithdraw(address(adapter)), 0);
        assertEq(target.maxDeposit(address(adapter)), 0);

        _toTarget(500 * UNIT);
        vm.prank(mayor);
        city.rebalance(address(adapter), address(0), 100 * UNIT, bytes32(0));

        vm.prank(guardianAddr);
        city.evacuate(address(adapter));
        assertEq(asset.balanceOf(address(city)), 1000 * UNIT - 0, "everything back in idle");
        assertEq(adapter.totalAssets(), 0);
    }

    function test_EvacuateWithNothingDeposited() public {
        vm.prank(guardianAddr);
        city.evacuate(address(adapter));
        assertEq(city.totalAssets(), 1000 * UNIT);
    }

    function test_InitRejectsTargetWithDifferentAsset() public {
        MockERC20Permit other = new MockERC20Permit();
        MockERC4626 wrong = new MockERC4626(other);
        vm.prank(owner);
        factory.setAdapterParams(address(impl4626), abi.encode(address(wrong)));

        address[] memory impls = new address[](1);
        impls[0] = address(impl4626);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.AssetMismatch.selector, address(asset), address(other)));
        factory.createCity("Wrong asset", "", 0, impls, "");
    }

    function test_OnlyVaultCanCallAdapter() public {
        vm.startPrank(mayor);
        vm.expectRevert();
        adapter.deposit(1);
        vm.expectRevert();
        adapter.withdraw(1);
        vm.expectRevert();
        adapter.withdrawAll();
        vm.stopPrank();
    }
}
