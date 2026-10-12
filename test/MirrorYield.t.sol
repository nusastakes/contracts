// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ApyFeed} from "../src/ApyFeed.sol";
import {CityVault} from "../src/CityVault.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {MirrorYieldAdapter} from "../src/adapters/MirrorYieldAdapter.sol";
import {MockBrokenReserve} from "./mocks/MockBrokenReserve.sol";

contract MirrorYieldTest is BaseTest {
    bytes32 internal constant SOURCE = keccak256("morpho-grove-steakhouse-ausd-mainnet");
    uint256 internal constant YEAR = 365 days;
    uint64 internal constant CHAIN = 2183018362218727504;

    event ApySet(bytes32 indexed sourceId, uint32 apyBps, uint64 observedAt, string label);
    event Shortfall(address indexed adapter, uint256 requested, uint256 available);

    address internal updater = makeAddr("updater");
    ApyFeed internal feed;
    YieldReserve internal reserve;
    MirrorYieldAdapter internal mirrorImpl;
    CityVault internal city;
    MirrorYieldAdapter internal mirror;

    function setUp() public override {
        super.setUp();
        feed = new ApyFeed(owner, updater, makeAddr("creForwarder"), CHAIN);
        reserve = new YieldReserve(owner, asset, ICityFactory(address(factory)), 10_000 * UNIT);
        asset.mint(address(reserve), 100_000 * UNIT);
        mirrorImpl = _mirrorImpl(address(reserve));
        vm.prank(owner);
        feed.setSourceLabel(SOURCE, "Morpho Grove x Steakhouse High Yield AUSD (mainnet)");

        (city, mirror) = _newCity(mayor, address(mirrorImpl));
        _fund(city, alice, 1000 * UNIT);
    }

    // ------------------------------------------------------------------ helpers

    function _mirrorImpl(address reserve_) internal returns (MirrorYieldAdapter impl) {
        impl = new MirrorYieldAdapter();
        vm.startPrank(owner);
        factory.setAllowedAdapter(address(impl), true);
        factory.setAdapterParams(address(impl), abi.encode(SOURCE, address(feed), reserve_));
        vm.stopPrank();
    }

    function _newCity(address founder, address impl) internal returns (CityVault c, MirrorYieldAdapter m) {
        address[] memory impls = new address[](1);
        impls[0] = impl;
        vm.prank(founder);
        c = CityVault(factory.createCity("Mirror", "", 0, impls, ""));
        m = MirrorYieldAdapter(c.adapters()[0]);
    }

    function _fund(CityVault c, address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(c), type(uint256).max);
        c.deposit(amount, who);
        vm.stopPrank();
    }

    function _setApy(uint32 bps) internal {
        vm.prank(updater);
        feed.setApy(SOURCE, bps, uint64(block.timestamp));
    }

    function _move(CityVault c, address mayor_, address from, address to, uint256 amount) internal {
        vm.prank(mayor_);
        c.rebalance(from, to, amount, bytes32(0));
    }

    function _moveToMirror(uint256 amount) internal {
        _move(city, mayor, address(0), address(mirror), amount);
    }

    // ------------------------------------------------------------------ 13.3 #1 accrual follows APY and time

    function test_AccrualMatchesApyAndTime() public {
        _setApy(1000); // 10%
        _moveToMirror(500 * UNIT);

        vm.warp(block.timestamp + YEAR);
        assertEq(mirror.totalAssets(), 550 * UNIT, "500 at 10% for a year");
        assertEq(city.totalAssets(), 1050 * UNIT);

        vm.warp(block.timestamp + YEAR / 2);
        assertEq(mirror.totalAssets(), 575 * UNIT, "simple interest, no compounding between touches");
    }

    function test_ApyChangeInTheMiddleIsAppliedOnlyFromThatMoment() public {
        _setApy(1000);
        _moveToMirror(500 * UNIT);

        vm.warp(block.timestamp + 100 days);
        _setApy(2000); // nobody touched the adapter in between
        vm.warp(block.timestamp + 100 days);

        uint256 expectedYield = 500 * UNIT * (1000 * uint256(100 days) + 2000 * uint256(100 days)) / (YEAR * 10_000);
        assertEq(mirror.totalAssets(), 500 * UNIT + expectedYield);
    }

    function test_ApyChangeAfterATouchIsAlsoCorrect() public {
        _setApy(1000);
        _moveToMirror(500 * UNIT);
        vm.warp(block.timestamp + 100 days);

        // A deposit touches (settles) the adapter before the rate changes.
        _moveToMirror(100 * UNIT);
        _setApy(0);
        vm.warp(block.timestamp + 100 days);

        uint256 firstLeg = 500 * UNIT * 1000 * uint256(100 days) / (YEAR * 10_000);
        assertEq(mirror.totalAssets(), 600 * UNIT + firstLeg, "zero rate afterwards earns nothing more");
    }

    function test_ZeroApyEarnsNothing() public {
        _moveToMirror(500 * UNIT);
        vm.warp(block.timestamp + YEAR);
        assertEq(mirror.totalAssets(), 500 * UNIT);
    }

    function test_YieldIsPaidFromReserveOnWithdraw() public {
        _setApy(1000);
        _moveToMirror(500 * UNIT);
        vm.warp(block.timestamp + YEAR);

        uint256 reserveBefore = asset.balanceOf(address(reserve));
        uint256 quotaBefore = reserve.quotaOf(address(mirror));
        vm.prank(guardianAddr);
        city.evacuate(address(mirror));

        assertEq(asset.balanceOf(address(city)), 500 * UNIT + 550 * UNIT, "idle 500 + principal 500 + yield 50");
        assertEq(reserveBefore - asset.balanceOf(address(reserve)), 50 * UNIT);
        assertEq(quotaBefore - reserve.quotaOf(address(mirror)), 50 * UNIT, "the paid yield used up budget");
        assertEq(mirror.principal(), 0);
        assertEq(mirror.owed(), 0);
    }

    function test_ResidentWithdrawsPrincipalPlusSimulatedYield() public {
        _setApy(1000);
        _moveToMirror(500 * UNIT);
        vm.warp(block.timestamp + YEAR);

        uint256 shares = city.balanceOf(alice);
        vm.prank(alice);
        uint256 out = city.redeem(shares, alice, alice);
        assertApproxEqAbs(out, 1050 * UNIT, 5);
    }

    // ------------------------------------------------------------------ 13.3 #2 bounded by the adapter's own budget

    function test_TotalAssetsNeverExceedsPrincipalPlusItsBudget() public {
        vm.prank(owner);
        reserve.setDefaultQuota(10 * UNIT);
        (CityVault cityB, MirrorYieldAdapter mirrorB) = _newCity(bob, address(mirrorImpl));
        _fund(cityB, carol, 1000 * UNIT);
        assertEq(reserve.quotaOf(address(mirrorB)), 10 * UNIT);

        _setApy(5000);
        _move(cityB, bob, address(0), address(mirrorB), 500 * UNIT);
        vm.warp(block.timestamp + YEAR); // 250 earned, budget 10

        assertEq(mirrorB.totalAssets(), 500 * UNIT + 10 * UNIT, "capped at the budget");

        vm.prank(guardianAddr);
        cityB.evacuate(address(mirrorB));
        assertEq(asset.balanceOf(address(cityB)), 1010 * UNIT, "principal always comes back, plus the budget");
        assertEq(reserve.quotaOf(address(mirrorB)), 0);
        assertEq(mirrorB.owed(), 240 * UNIT, "the unpaid part is remembered, not invented");
    }

    function test_AdapterWithoutBudgetStillReturnsPrincipal() public {
        vm.prank(owner);
        reserve.setDefaultQuota(0);
        (CityVault cityC, MirrorYieldAdapter mirrorC) = _newCity(bob, address(mirrorImpl));
        _fund(cityC, carol, 1000 * UNIT);
        _setApy(2000);
        _move(cityC, bob, address(0), address(mirrorC), 500 * UNIT);
        vm.warp(block.timestamp + YEAR);

        assertEq(mirrorC.totalAssets(), 500 * UNIT);
        uint256 shares = cityC.balanceOf(carol);
        vm.prank(carol);
        assertEq(cityC.redeem(shares, carol, carol), 1000 * UNIT, "principal is never at risk from the reserve");
    }

    function test_ShortfallIsReportedAndBacklogPaidAfterTopUp() public {
        vm.prank(owner);
        reserve.setDefaultQuota(10 * UNIT);
        (CityVault cityB, MirrorYieldAdapter mirrorB) = _newCity(bob, address(mirrorImpl));
        _fund(cityB, carol, 1000 * UNIT);
        _setApy(5000);
        _move(cityB, bob, address(0), address(mirrorB), 500 * UNIT);
        vm.warp(block.timestamp + YEAR); // 250 owed, budget 10

        vm.expectEmit(true, false, false, true);
        emit Shortfall(address(mirrorB), 250 * UNIT, 10 * UNIT);
        _move(cityB, bob, address(mirrorB), address(0), 1); // any touch settles
        assertEq(mirrorB.owed(), 240 * UNIT);

        vm.prank(owner);
        reserve.grantQuota(address(mirrorB), 300 * UNIT);
        _move(cityB, bob, address(mirrorB), address(0), 1);
        assertEq(mirrorB.owed(), 0, "topped-up budget pays the backlog");
    }

    // ------------------------------------------------------------------ F-01 regression: shared reserve

    function test_TwoCitiesSharingAReserveNeverReportMoreYieldThanTheReserveHolds() public {
        YieldReserve small = new YieldReserve(owner, asset, ICityFactory(address(factory)), 100 * UNIT);
        asset.mint(address(small), 100 * UNIT);
        MirrorYieldAdapter impl2 = _mirrorImpl(address(small));

        (CityVault cityA, MirrorYieldAdapter mirrorA) = _newCity(mayor, address(impl2));
        (CityVault cityB, MirrorYieldAdapter mirrorB) = _newCity(bob, address(impl2));
        _fund(cityA, alice, 1000 * UNIT);
        _fund(cityB, carol, 1000 * UNIT);
        assertEq(small.quotaOf(address(mirrorA)) + small.quotaOf(address(mirrorB)), 100 * UNIT);

        _setApy(5000);
        for (uint256 i; i < 2; ++i) {
            _move(cityA, mayor, address(0), address(mirrorA), 500 * UNIT);
            _move(cityB, bob, address(0), address(mirrorB), 500 * UNIT);
        }
        vm.warp(block.timestamp + 73 days); // each would earn 100

        uint256 reportedYield = (mirrorA.totalAssets() - 1000 * UNIT) + (mirrorB.totalAssets() - 1000 * UNIT);
        assertLe(reportedYield, asset.balanceOf(address(small)), "yield counted twice");
        assertEq(reportedYield, 100 * UNIT);

        // Both cities can fully exit, and what they get adds up to deposits plus the real reserve.
        uint256 sharesA = cityA.balanceOf(alice);
        uint256 sharesB = cityB.balanceOf(carol);
        vm.prank(alice);
        uint256 outA = cityA.redeem(sharesA, alice, alice);
        vm.prank(carol);
        uint256 outB = cityB.redeem(sharesB, carol, carol);
        assertApproxEqAbs(outA + outB, 2000 * UNIT + 100 * UNIT, 10);
        assertLe(outA + outB, 2000 * UNIT + 100 * UNIT);
    }

    function test_TwoMirrorAdaptersOfOneCityOnOneReserveCanFullyExit() public {
        YieldReserve small = new YieldReserve(owner, asset, ICityFactory(address(factory)), 60 * UNIT);
        asset.mint(address(small), 100 * UNIT);
        MirrorYieldAdapter m1 = _mirrorImpl(address(small));
        MirrorYieldAdapter m2 = _mirrorImpl(address(small));

        address[] memory impls = new address[](2);
        impls[0] = address(m1);
        impls[1] = address(m2);
        vm.prank(bob);
        CityVault c = CityVault(factory.createCity("Two mirrors", "", 0, impls, ""));
        MirrorYieldAdapter a1 = MirrorYieldAdapter(c.adapters()[0]);
        MirrorYieldAdapter a2 = MirrorYieldAdapter(c.adapters()[1]);
        assertEq(small.quotaOf(address(a1)), 60 * UNIT);
        assertEq(small.quotaOf(address(a2)), 40 * UNIT, "second adapter gets what is left");

        _fund(c, carol, 1000 * UNIT);
        _setApy(5000);
        _move(c, bob, address(0), address(a1), 400 * UNIT);
        _move(c, bob, address(0), address(a2), 400 * UNIT);
        vm.warp(block.timestamp + YEAR); // each would earn 200

        assertEq(c.totalAssets(), 1000 * UNIT + 100 * UNIT);
        uint256 shares = c.balanceOf(carol);
        uint256 previewed = c.previewRedeem(shares);
        vm.prank(carol);
        uint256 out = c.redeem(shares, carol, carol); // used to revert in the reviewer's PoC
        assertApproxEqAbs(out, previewed, 2);
        assertApproxEqAbs(out, 1100 * UNIT, 5);
    }

    // ------------------------------------------------------------------ F-03 regression: broken reserve

    function test_FailingReserveCannotTrapPrincipal() public {
        MockBrokenReserve broken = new MockBrokenReserve();
        MirrorYieldAdapter implBroken = _mirrorImpl(address(broken));
        (CityVault c, MirrorYieldAdapter m) = _newCity(bob, address(implBroken));
        _fund(c, carol, 1000 * UNIT);
        _setApy(2000);
        _move(c, bob, address(0), address(m), 500 * UNIT);
        vm.warp(block.timestamp + 30 days); // yield is owed, but pay() reverts

        vm.prank(guardianAddr);
        c.evacuate(address(m)); // _settle swallows the failure
        assertEq(asset.balanceOf(address(c)), 1000 * UNIT, "principal is back in the vault");
        assertEq(m.principal(), 0);
        assertGt(m.owed(), 0, "the unpaid yield is remembered");
    }

    function test_ReserveOfAnotherFactoryCannotBeUsedToFoundACity() public {
        CityVaultFactoryProbe probe = new CityVaultFactoryProbe();
        YieldReserve foreign = new YieldReserve(owner, asset, ICityFactory(probe.asFactory()), 1);
        MirrorYieldAdapter implForeign = _mirrorImpl(address(foreign));
        address[] memory impls = new address[](1);
        impls[0] = address(implForeign);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.NotAdapter.selector, factoryNextClone()));
        factory.createCity("Misconfigured", "", 0, impls, "");
    }

    /// @dev The clone address is deterministic from the factory's nonce, so predict it for the expected error.
    function factoryNextClone() internal view returns (address) {
        // CityVault is deployed first (nonce n), the clone second (nonce n+1); Clones.clone uses CREATE.
        return vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)) + 1);
    }

    // ------------------------------------------------------------------ views and lock-downs

    function test_IsSimulatedAndSourceId() public view {
        assertTrue(mirror.isSimulated());
        assertEq(mirror.sourceId(), SOURCE);
        assertEq(mirror.asset(), address(asset));
        assertEq(mirror.vault(), address(city));
    }

    function test_OnlyVaultCanMoveMirrorFunds() public {
        vm.startPrank(mayor);
        vm.expectRevert();
        mirror.withdraw(1);
        vm.expectRevert();
        mirror.deposit(1);
        vm.expectRevert();
        mirror.withdrawAll();
        vm.stopPrank();
    }

    function test_ImplementationAndCloneCannotBeReinitialised() public {
        bytes memory params = abi.encode(SOURCE, address(feed), address(reserve));
        vm.expectRevert();
        mirrorImpl.initialize(address(1), address(asset), params);
        vm.expectRevert();
        mirror.initialize(address(1), address(asset), params);
    }

    // ------------------------------------------------------------------ reserve ledger

    function test_ReserveOnlyEnrollsAndPaysFactoryAdapterClones() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.NotAdapter.selector, bob));
        reserve.enroll();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.NotAdapter.selector, bob));
        reserve.pay(bob, 1);

        // Even the implementation contract is not a clone.
        vm.prank(address(mirrorImpl));
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.NotAdapter.selector, address(mirrorImpl)));
        reserve.enroll();

        // A clone can enroll only once.
        vm.prank(address(mirror));
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.AlreadyEnrolled.selector, address(mirror)));
        reserve.enroll();
    }

    function test_ReserveAccountingKeepsBudgetsBelowBalance() public {
        assertEq(reserve.totalAllocated(), 10_000 * UNIT);
        assertEq(reserve.unallocated(), 90_000 * UNIT);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.ExceedsUnallocated.selector, 90_001 * UNIT, 90_000 * UNIT));
        reserve.rescue(owner, 90_001 * UNIT);
        reserve.rescue(owner, 90_000 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.ExceedsUnallocated.selector, 1, 0));
        reserve.grantQuota(address(mirror), 1);
        vm.stopPrank();

        assertEq(asset.balanceOf(address(reserve)), reserve.totalAllocated(), "what is left is exactly the budgets");
    }

    function test_OnlyOwnerCanManageTheReserve() public {
        vm.startPrank(bob);
        vm.expectRevert();
        reserve.rescue(bob, 1);
        vm.expectRevert();
        reserve.grantQuota(address(mirror), 1);
        vm.expectRevert();
        reserve.setDefaultQuota(1);
        vm.stopPrank();
    }

    function test_GrantQuotaOnlyToEnrolledAdapters() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldReserve.NotAdapter.selector, bob));
        reserve.grantQuota(bob, 1);
    }

    // ------------------------------------------------------------------ 13.3 #3 ApyFeed access and bounds

    function test_ApyFeedOnlyUpdaterMayWrite() public {
        vm.prank(bob);
        vm.expectRevert(ApyFeed.NotUpdater.selector);
        feed.setApy(SOURCE, 100, uint64(block.timestamp));

        vm.prank(owner);
        vm.expectRevert(ApyFeed.NotUpdater.selector);
        feed.setApy(SOURCE, 100, uint64(block.timestamp));

        _setApy(100);
        (uint32 apy, uint64 observed,) = feed.latest(SOURCE);
        assertEq(apy, 100);
        assertEq(observed, uint64(block.timestamp));
    }

    function test_ApyFeedRejectsInsaneValues() public {
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ApyFeed.ApyTooHigh.selector, uint32(5001)));
        feed.setApy(SOURCE, 5001, uint64(block.timestamp));

        _setApy(5000); // the ceiling itself is fine
    }

    function test_ApyFeedRejectsStaleAndFutureObservations() public {
        vm.warp(1_000_000);
        vm.prank(updater);
        feed.setApy(SOURCE, 100, 999_000);

        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ApyFeed.StaleObservation.selector, uint64(998_000), uint64(999_000)));
        feed.setApy(SOURCE, 200, 998_000);

        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ApyFeed.ObservationInFuture.selector, uint64(1_000_001)));
        feed.setApy(SOURCE, 200, 1_000_001);
    }

    function test_ApyFeedEmitsEventWithSourceLabel() public {
        vm.prank(owner);
        feed.setSourceLabel(SOURCE, "Morpho Grove x Steakhouse High Yield AUSD (mainnet)");
        vm.expectEmit(true, false, false, true);
        emit ApySet(SOURCE, 168, uint64(block.timestamp), "Morpho Grove x Steakhouse High Yield AUSD (mainnet)");
        _setApy(168);
    }

    function test_ApyFeedOwnerCanRotateUpdater() public {
        vm.prank(owner);
        feed.setUpdater(bob);
        vm.prank(updater);
        vm.expectRevert(ApyFeed.NotUpdater.selector);
        feed.setApy(SOURCE, 1, uint64(block.timestamp));
        vm.prank(bob);
        feed.setApy(SOURCE, 1, uint64(block.timestamp));
    }

    function test_ApyFeedIndexIsExactAcrossUpdates() public {
        uint256 t0 = block.timestamp;
        _setApy(1000);
        vm.warp(t0 + 10 days);
        _setApy(500);
        vm.warp(t0 + 30 days);
        assertEq(feed.currentIndex(SOURCE), 1000 * uint256(10 days) + 500 * uint256(20 days));
    }
}

/// @dev A stand-in "other factory" whose `isAdapterClone` is always false.
contract CityVaultFactoryProbe {
    function asFactory() external view returns (address) {
        return address(this);
    }

    function isAdapterClone(address) external pure returns (bool) {
        return false;
    }
}
