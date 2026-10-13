// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ApyFeed} from "../src/ApyFeed.sol";
import {CityVault} from "../src/CityVault.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {TunedMirrorAdapter} from "../src/adapters/TunedMirrorAdapter.sol";

/// @notice The tuned mirror: the city's own tuning is stored on-chain, only the mayor or the mayor's live session key
/// may change it, yield follows the APY written under the adapter's own feed key, and accrued yield is settled at the
/// old rate before a change.
contract TunedMirrorTest is BaseTest {
    bytes32 internal constant BASE = keccak256(bytes("ba0f675f-9f14-407b-b278-66d8f59f49ca"));
    uint256 internal constant YEAR = 365 days;

    address internal updater = makeAddr("updater");
    ApyFeed internal feed;
    YieldReserve internal reserve;
    TunedMirrorAdapter internal impl;
    CityVault internal city;
    TunedMirrorAdapter internal tuned;

    function setUp() public override {
        super.setUp();
        feed = new ApyFeed(owner, updater, makeAddr("creForwarder"), 1);
        reserve = new YieldReserve(owner, asset, ICityFactory(address(factory)), 10_000 * UNIT);
        asset.mint(address(reserve), 100_000 * UNIT);
        impl = new TunedMirrorAdapter();
        vm.startPrank(owner);
        factory.setAllowedAdapter(address(impl), true);
        factory.setAdapterParams(address(impl), abi.encode(BASE, address(feed), address(reserve)));
        vm.stopPrank();
        address[] memory impls = new address[](1);
        impls[0] = address(impl);
        vm.prank(mayor);
        city = CityVault(factory.createCity("Tuned", "", 0, impls, ""));
        tuned = TunedMirrorAdapter(city.adapters()[0]);
        asset.mint(alice, 1000 * UNIT);
        vm.startPrank(alice);
        asset.approve(address(city), type(uint256).max);
        city.deposit(1000 * UNIT, alice);
        vm.stopPrank();
    }

    function _ownKey() internal view returns (bytes32) {
        return keccak256(abi.encode("nusastakes.tuned", address(tuned)));
    }

    function _setOwnApy(uint32 bps) internal {
        vm.prank(updater);
        feed.setApy(_ownKey(), bps, uint64(block.timestamp));
    }

    function test_InitUsesOwnFeedKeyAndKeepsBase() public view {
        assertEq(tuned.baseSourceId(), BASE);
        assertEq(tuned.sourceId(), _ownKey());
        assertEq(tuned.tuning().length, 0);
        assertTrue(tuned.isSimulated());
    }

    function test_EarnsNothingUntilKeeperWritesItsKey() public {
        vm.prank(mayor);
        city.rebalance(address(0), address(tuned), 500 * UNIT, bytes32(0));
        vm.prank(updater);
        feed.setApy(BASE, 900, uint64(block.timestamp)); // the base pool alone does not pay this adapter
        vm.warp(block.timestamp + YEAR);
        assertEq(tuned.totalAssets(), 500 * UNIT);
    }

    function test_YieldFollowsOwnKey() public {
        _setOwnApy(1200);
        vm.prank(mayor);
        city.rebalance(address(0), address(tuned), 500 * UNIT, bytes32(0));
        vm.warp(block.timestamp + YEAR);
        assertEq(tuned.totalAssets(), 560 * UNIT);
    }

    function test_OnlyMayorOrLiveSessionKeyTunes() public {
        bytes memory t = abi.encode(uint8(1), uint16(200), true, uint16(0), uint256(0));
        vm.expectRevert(TunedMirrorAdapter.NotMayorOrSessionKey.selector);
        vm.prank(bob);
        tuned.setTuning(t);

        vm.prank(mayor);
        tuned.setTuning(t);
        assertEq(tuned.tuning(), t);
        assertEq(tuned.tunedAt(), block.timestamp);

        vm.prank(mayor);
        city.setSessionKey(sessionKey, uint64(block.timestamp + 1 hours), 1000);
        bytes memory t2 = abi.encode(uint8(1), uint16(100), false, uint16(0), uint256(0));
        vm.prank(sessionKey);
        tuned.setTuning(t2);
        assertEq(tuned.tuning(), t2);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(TunedMirrorAdapter.NotMayorOrSessionKey.selector);
        vm.prank(sessionKey);
        tuned.setTuning(t);
    }

    function test_TuningTooLongRejected() public {
        vm.expectRevert(TunedMirrorAdapter.TuningTooLong.selector);
        vm.prank(mayor);
        tuned.setTuning(new bytes(257));
    }

    function test_ChangeSettlesAtOldRateFirst() public {
        _setOwnApy(1000);
        vm.prank(mayor);
        city.rebalance(address(0), address(tuned), 500 * UNIT, bytes32(0));
        vm.warp(block.timestamp + YEAR);
        vm.prank(mayor);
        tuned.setTuning(abi.encode(uint8(1), uint16(300), true, uint16(0), uint256(0)));
        assertEq(tuned.principal(), 550 * UNIT, "a year at 10% booked before the change");
        _setOwnApy(2000);
        vm.warp(block.timestamp + YEAR);
        assertEq(tuned.totalAssets(), 660 * UNIT);
    }
}
