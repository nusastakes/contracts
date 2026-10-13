// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ApyFeed} from "../src/ApyFeed.sol";
import {CityServices} from "../src/CityServices.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {BaseTest} from "./Base.t.sol";

/// @notice Launchpad and APY prediction services: only the mayor configures them, fees stream into the city vault
/// (so residents earn them through the share price, never the mayor directly), the curve never pays out more than it
/// holds, and markets resolve from the feed only, measured after betting closed.
contract CityServicesTest is BaseTest {
    CityServices internal svc;
    ApyFeed internal feed;
    address internal updater = makeAddr("updater");
    bytes32 internal constant SRC = keccak256("aave-ausd");
    uint64 internal constant DRIP = 12 hours;

    function setUp() public override {
        super.setUp();
        feed = new ApyFeed(owner, updater, makeAddr("creForwarder"), 1);
        svc = new CityServices(asset, ICityFactory(address(factory)), feed, 1 * UNIT, 5_000 * UNIT, DRIP, true);
        vm.prank(updater);
        feed.setApy(SRC, 600, uint64(block.timestamp));
    }

    function _on(uint8 kind, uint16 feeBps) internal {
        vm.prank(mayor);
        svc.setService(address(vault), kind, true, feeBps);
    }

    function _fund(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(svc), type(uint256).max);
    }

    // ---------------------------------------------------------------- access

    function test_OnlyMayorSetsService() public {
        vm.expectRevert(CityServices.NotMayor.selector);
        vm.prank(bob);
        svc.setService(address(vault), 1, true, 100);
    }

    function test_RejectsNonCity() public {
        vm.expectRevert(abi.encodeWithSelector(CityServices.NotCity.selector, bob));
        vm.prank(mayor);
        svc.setService(bob, 1, true, 100);
    }

    function test_FeeCapped() public {
        vm.expectRevert(abi.encodeWithSelector(CityServices.FeeTooHigh.selector, uint16(301)));
        vm.prank(mayor);
        svc.setService(address(vault), 1, true, 301);
    }

    function test_UnknownKind() public {
        vm.expectRevert(abi.encodeWithSelector(CityServices.UnknownKind.selector, uint8(3)));
        vm.prank(mayor);
        svc.setService(address(vault), 3, true, 100);
    }

    function test_PredictionHeldBackWhenDisabled() public {
        CityServices held = new CityServices(asset, ICityFactory(address(factory)), feed, 1 * UNIT, 5_000 * UNIT, DRIP, false);
        vm.startPrank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityServices.UnknownKind.selector, uint8(2)));
        held.setService(address(vault), 2, true, 100);
        held.setService(address(vault), 1, true, 100);
        vm.expectRevert(abi.encodeWithSelector(CityServices.ServiceOff.selector, address(vault), uint8(2)));
        held.openMarket(address(vault), SRC, 650, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.stopPrank();
    }

    function test_LaunchNeedsServiceOn() public {
        _fund(bob, 10 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(CityServices.ServiceOff.selector, address(vault), uint8(1)));
        vm.prank(bob);
        svc.launch(address(vault), "Kopi", "KOPI", 0, 0);
    }

    // ---------------------------------------------------------------- launchpad

    function test_LaunchFeeStreamsToVaultAndRaisesSharePrice() public {
        _deposit(alice, 100 * UNIT);
        _on(1, 100);
        uint256 before = vault.totalAssets();
        _fund(bob, 10 * UNIT);
        vm.prank(bob);
        (address token,) = svc.launch(address(vault), "Kopi Kota", "KOPI", 0, 0);
        assertEq(vault.totalAssets(), before, "fee does not land at once");
        (uint256 due, uint256 pending) = svc.releasable(address(vault));
        assertEq(due, 0);
        assertEq(pending, 1 * UNIT);
        vm.warp(block.timestamp + DRIP / 2);
        svc.release(address(vault));
        assertEq(vault.totalAssets(), before + 0.5e6, "half streamed after half the period");
        vm.warp(block.timestamp + DRIP);
        svc.release(address(vault));
        assertEq(vault.totalAssets(), before + 1 * UNIT, "all streamed");
        assertGt(_assetsOf(alice), 100 * UNIT, "resident earns the fee");
        assertEq(IERC20(token).balanceOf(address(svc)), svc.TOKEN_SUPPLY());
        (uint128 volume, uint128 fees, uint64 uses) = svc.stats(address(vault), 1);
        assertEq(volume, 1 * UNIT);
        assertEq(fees, 1 * UNIT);
        assertEq(uses, 1);
        assertEq(svc.tokensOf(address(vault)).length, 1);
    }

    function test_FeeWaitsWhileCityEmptyAndNeverGoesToMayor() public {
        _on(1, 100);
        _fund(bob, 10 * UNIT);
        vm.prank(bob);
        svc.launch(address(vault), "Kopi", "KOPI", 0, 0);
        vm.warp(block.timestamp + 2 * DRIP);
        svc.release(address(vault));
        assertEq(asset.balanceOf(mayor), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        (, uint256 pending) = svc.releasable(address(vault));
        assertEq(pending, 1 * UNIT);
        _deposit(alice, 100 * UNIT);
        vm.warp(block.timestamp + 2 * DRIP);
        svc.release(address(vault));
        assertEq(asset.balanceOf(address(vault)), 101 * UNIT);
    }

    /// @dev A whale that deposits right before a big fee and leaves right after gets only a sliver of it.
    function test_JustInTimeDepositGainsLittle() public {
        _deposit(alice, 100 * UNIT);
        _on(2, 300);
        vm.prank(mayor);
        uint256 id = svc.openMarket(address(vault), SRC, 650, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        _deposit(carol, 10_000 * UNIT);
        _fund(bob, 10_000 * UNIT);
        vm.prank(bob);
        svc.predict(id, true, 10_000 * UNIT); // 300 AUSD fee
        vm.warp(block.timestamp + 1 minutes);
        svc.release(address(vault));
        uint256 carolGain = _assetsOf(carol) - 10_000 * UNIT;
        assertLt(carolGain, 1 * UNIT, "JIT depositor captures under 1 AUSD of a 300 AUSD fee");
    }

    function test_BuySellRoundTripLosesOnlyFees() public {
        _deposit(alice, 100 * UNIT);
        _on(1, 100);
        _fund(bob, 1_000 * UNIT);
        vm.startPrank(bob);
        (address token, uint256 got) = svc.launch(address(vault), "Kopi", "KOPI", 100 * UNIT, 1);
        assertGt(got, 0);
        IERC20(token).approve(address(svc), got);
        uint256 out = svc.sell(token, got, 0);
        vm.stopPrank();
        // 1% in, 1% out, plus curve rounding.
        assertApproxEqAbs(out, 98.01e6, 2);
        assertLe(out, 98.01e6);
        (, uint256 reserve,) = svc.curves(token);
        assertLe(reserve, 2, "curve keeps at most rounding dust");
        (, uint128 fees,) = svc.stats(address(vault), 1);
        assertApproxEqAbs(fees, 1 * UNIT + 1 * UNIT + 0.99e6, 2);
        (, uint256 pending) = svc.releasable(address(vault));
        assertApproxEqAbs(pending, fees, 2);
    }

    function test_PriceRisesWithBuys() public {
        _on(1, 0);
        _fund(bob, 10_000 * UNIT);
        vm.startPrank(bob);
        (address token,) = svc.launch(address(vault), "Kopi", "KOPI", 0, 0);
        uint256 p0 = svc.price(token);
        svc.buy(token, 1_000 * UNIT, 1);
        uint256 p1 = svc.price(token);
        vm.stopPrank();
        assertGt(p1, p0);
        // Starting price = virtual reserve / supply = 5,000 AUSD / 1e9 tokens.
        assertEq(p0, 5);
    }

    function test_SlippageGuard() public {
        _on(1, 100);
        _fund(bob, 1_000 * UNIT);
        vm.startPrank(bob);
        (address token,) = svc.launch(address(vault), "Kopi", "KOPI", 0, 0);
        (uint256 q,) = svc.quoteBuy(token, 10 * UNIT);
        vm.expectRevert();
        svc.buy(token, 10 * UNIT, q + 1);
        assertEq(svc.buy(token, 10 * UNIT, q), q);
        vm.stopPrank();
    }

    function test_BadNameRejected() public {
        _on(1, 100);
        _fund(bob, 10 * UNIT);
        vm.startPrank(bob);
        vm.expectRevert(CityServices.BadName.selector);
        svc.launch(address(vault), "", "KOPI", 0, 0);
        vm.expectRevert(CityServices.BadName.selector);
        svc.launch(address(vault), "Kopi", "TOOLONGSYM", 0, 0);
        vm.stopPrank();
    }

    function test_TradingStillWorksAfterServiceOff() public {
        _on(1, 100);
        _fund(bob, 100 * UNIT);
        vm.startPrank(bob);
        (address token, uint256 got) = svc.launch(address(vault), "Kopi", "KOPI", 50 * UNIT, 1);
        vm.stopPrank();
        vm.prank(mayor);
        svc.setService(address(vault), 1, false, 100);
        vm.startPrank(bob);
        IERC20(token).approve(address(svc), got);
        assertGt(svc.sell(token, got, 0), 0);
        vm.stopPrank();
    }

    /// @dev Many traders in random order: the curve never owes more than it holds, and everyone can exit.
    function testFuzz_CurveSolvent(uint96[6] memory buys) public {
        _on(1, 250);
        _fund(bob, 1 * UNIT);
        vm.prank(bob);
        (address token,) = svc.launch(address(vault), "Kopi", "KOPI", 0, 0);
        address[6] memory who;
        uint256[6] memory held;
        for (uint256 i; i < 6; i++) {
            who[i] = makeAddr(string(abi.encode(i)));
            uint256 amt = bound(uint256(buys[i]), 1, 50_000 * UNIT);
            _fund(who[i], amt);
            vm.prank(who[i]);
            held[i] = svc.buy(token, amt, 1);
        }
        for (uint256 i = 6; i > 0; i--) {
            vm.startPrank(who[i - 1]);
            IERC20(token).approve(address(svc), held[i - 1]);
            svc.sell(token, held[i - 1], 0);
            vm.stopPrank();
        }
        (, uint256 reserve, uint256 tokens) = svc.curves(token);
        assertEq(tokens, svc.TOKEN_SUPPLY());
        assertLe(reserve, 10, "only rounding dust left");
        (, uint256 pending) = svc.releasable(address(vault));
        assertGe(asset.balanceOf(address(svc)), reserve + pending);
    }

    // ---------------------------------------------------------------- prediction

    /// @dev Betting closes after `dt`, the rate is measured `dt` later.
    function _open(uint64 dt) internal returns (uint256 id) {
        _on(2, 200);
        vm.prank(mayor);
        id = svc.openMarket(address(vault), SRC, 650, uint64(block.timestamp) + dt, uint64(block.timestamp) + 2 * dt);
    }

    function test_OnlyMayorOpensMarket() public {
        _on(2, 200);
        vm.expectRevert(CityServices.NotMayor.selector);
        vm.prank(bob);
        svc.openMarket(address(vault), SRC, 650, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
    }

    function test_MarketNeedsFeedData() public {
        _on(2, 200);
        bytes32 none = keccak256("none");
        vm.expectRevert(abi.encodeWithSelector(CityServices.NoFeedData.selector, none));
        vm.prank(mayor);
        svc.openMarket(address(vault), none, 650, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
    }

    function test_MarketCloseTimeBounds() public {
        _on(2, 200);
        vm.startPrank(mayor);
        uint64 t = uint64(block.timestamp);
        vm.expectRevert();
        svc.openMarket(address(vault), SRC, 650, t + 1 minutes, t + 1 hours);
        vm.expectRevert();
        svc.openMarket(address(vault), SRC, 650, t + 1 hours, t + 1 hours + 1 minutes);
        vm.expectRevert();
        svc.openMarket(address(vault), SRC, 650, t + 1 hours, t + 31 days);
        vm.stopPrank();
    }

    function test_PredictResolveClaim() public {
        _deposit(alice, 100 * UNIT);
        uint256 id = _open(1 hours);
        _fund(bob, 100 * UNIT);
        _fund(carol, 100 * UNIT);
        vm.prank(bob);
        svc.predict(id, true, 100 * UNIT); // net 98
        vm.prank(carol);
        svc.predict(id, false, 50 * UNIT); // net 49
        (, uint256 pending) = svc.releasable(address(vault));
        assertEq(pending, 3 * UNIT, "2% of 150 owed to the city");

        vm.expectRevert(abi.encodeWithSelector(CityServices.MarketNotClosed.selector, id));
        svc.resolve(id);

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CityServices.MarketClosed.selector, id));
        vm.prank(carol);
        svc.predict(id, false, 1 * UNIT);
        // Betting is closed but the rate is measured only an hour later.
        vm.prank(updater);
        feed.setApy(SRC, 900, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(CityServices.MarketNotClosed.selector, id));
        svc.resolve(id);

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CityServices.NoObservationAfterClose.selector, id));
        svc.resolve(id);

        vm.prank(updater);
        feed.setApy(SRC, 700, uint64(block.timestamp));
        svc.resolve(id);
        assertEq(uint8(svc.market(id).outcome), 1, "above");

        assertEq(svc.claimable(id, carol), 0);
        vm.prank(bob);
        assertEq(svc.claim(id), 147 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(CityServices.NothingToClaim.selector, id));
        vm.prank(bob);
        svc.claim(id);
    }

    function test_OneSidedMarketIsVoidAndRefunds() public {
        uint256 id = _open(10 minutes);
        _fund(bob, 10 * UNIT);
        vm.prank(bob);
        svc.predict(id, true, 10 * UNIT);
        vm.warp(block.timestamp + 20 minutes);
        vm.prank(updater);
        feed.setApy(SRC, 500, uint64(block.timestamp));
        svc.resolve(id);
        assertEq(uint8(svc.market(id).outcome), 3);
        vm.prank(bob);
        assertEq(svc.claim(id), 9.8e6);
    }

    function test_SilentFeedCanBeVoided() public {
        uint256 id = _open(10 minutes);
        _fund(bob, 10 * UNIT);
        _fund(carol, 10 * UNIT);
        vm.prank(bob);
        svc.predict(id, true, 10 * UNIT);
        vm.prank(carol);
        svc.predict(id, false, 10 * UNIT);
        vm.warp(block.timestamp + 20 minutes + 1 days);
        vm.expectRevert(abi.encodeWithSelector(CityServices.TooEarlyToVoid.selector, id));
        svc.voidMarket(id);
        vm.warp(block.timestamp + 3 days);
        svc.voidMarket(id);
        vm.prank(bob);
        assertEq(svc.claim(id), 9.8e6);
        vm.prank(carol);
        assertEq(svc.claim(id), 9.8e6);
    }

    function test_MarketsListedPerCity() public {
        _open(1 hours);
        _open(2 hours);
        assertEq(svc.marketsOf(address(vault)).length, 2);
        assertEq(svc.marketCount(), 2);
    }
}
