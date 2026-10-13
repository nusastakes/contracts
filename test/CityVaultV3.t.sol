// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {BaseTest} from "./Base.t.sol";
import {CityVault} from "../src/CityVault.sol";

/// @notice Vault v3: a broken adapter no longer locks the city (F-02), the session key has a cumulative hourly budget
/// (B1.10 / F-05), and the mayor can store a city style on-chain.
contract CityVaultV3Test is BaseTest {
    address internal stranger = makeAddr("stranger");

    /// Alice 600 and Bob 400 deposit 1000; 500 goes to adapter A, 200 to adapter B, 300 stays idle.
    function _fundedCity() internal {
        _deposit(alice, 600 * UNIT);
        _deposit(bob, 400 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        _move(address(0), address(adapterB), 200 * UNIT);
    }

    // ───────────────────────────── F-02: quarantine ─────────────────────────────

    function test_QuarantineRefusesAHealthyAdapter() public {
        _fundedCity();
        vm.expectRevert(abi.encodeWithSelector(CityVault.AdapterNotBroken.selector, address(adapterA)));
        vault.quarantine(address(adapterA));
        vm.expectRevert(abi.encodeWithSelector(CityVault.UnknownAdapter.selector, stranger));
        vault.quarantine(stranger);
        assertEq(vault.quarantinedCount(), 0);
    }

    function test_ABrokenAdapterLocksTheCityUntilAnyoneQuarantinesIt() public {
        _fundedCity();
        adapterA.setMode(1);
        vm.expectRevert();
        vault.totalAssets();
        asset.mint(carol, 10 * UNIT);
        vm.startPrank(carol);
        asset.approve(address(vault), 10 * UNIT);
        vm.expectRevert();
        vault.deposit(10 * UNIT, carol);
        vm.stopPrank();

        vm.prank(stranger); // nobody special is needed
        vault.quarantine(address(adapterA));
        assertTrue(vault.quarantined(address(adapterA)));
        assertEq(vault.quarantinedCount(), 1);
        assertEq(vault.totalAssets(), 500 * UNIT, "a quarantined adapter counts as zero: 300 idle + 200 in adapter B");

        vm.expectRevert(abi.encodeWithSelector(CityVault.AlreadyQuarantined.selector, address(adapterA)));
        vault.quarantine(address(adapterA));
    }

    /// Finding V-01 of the independent review: moving money out of a quarantined adapter used to leave its frozen value on
    /// the books as well, so the same money counted twice. A quarantined adapter now counts as zero, so there is nothing to
    /// double count and the books equal the money that is really there.
    function test_MovingMoneyOutOfAQuarantinedAdapterNeverCountsItTwice() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        assertEq(vault.totalAssets(), 500 * UNIT);

        // The withdrawal itself still works, only totalAssets() fails. The per-call limit is half of the (reduced) total, so
        // getting everything out takes a few calls, and each one makes the total bigger.
        for (uint256 i; i < 6 && asset.balanceOf(address(adapterA)) > 0; ++i) {
            uint256 step = vault.totalAssets() / 2;
            uint256 left = asset.balanceOf(address(adapterA));
            _move(address(adapterA), address(0), step < left ? step : left);
        }
        assertEq(asset.balanceOf(address(adapterA)), 0);
        assertEq(vault.totalAssets(), 1000 * UNIT, "500 + 500 idle = exactly what exists");
        assertEq(asset.balanceOf(address(vault)) + adapterB.totalAssets() + asset.balanceOf(address(adapterA)), 1000 * UNIT);

        vault.harvestFee();
        assertEq(vault.balanceOf(mayor), 0, "no fee is minted on profit that does not exist");

        // Fair exits: Alice owns 60%, Bob 40%, whoever leaves first.
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(alice);
        assertApproxEqAbs(vault.redeem(aliceShares, alice, alice), 600 * UNIT, 2);
        vm.prank(bob);
        assertApproxEqAbs(vault.redeem(bobShares, bob, bob), 400 * UNIT, 2);
    }

    function test_TheGuardiansEvacuationOfAQuarantinedAdapterIsAlsoExact() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        vm.prank(guardianAddr);
        vault.evacuate(address(adapterA));
        assertEq(vault.totalAssets(), 1000 * UNIT);
    }

    function test_TheSessionKeyCannotCreatePhantomAssetsEither() public {
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 400 * UNIT);
        vm.prank(mayor);
        vault.setSessionKey(sessionKey, uint64(block.timestamp + 1 days), 5000);
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        // The budget is 20% of the reduced total (600), so 100 fits.
        vm.prank(sessionKey);
        vault.rebalance(address(adapterA), address(0), 100 * UNIT, bytes32(0));
        assertEq(vault.totalAssets(), 700 * UNIT, "600 idle before + 100 moved back; the other 300 are still in A");
    }

    function test_DepositsAndNewMoneyStopWhileQuarantined() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        assertEq(vault.maxDeposit(carol), 0);
        assertEq(vault.maxMint(carol), 0);
        asset.mint(carol, 10 * UNIT);
        vm.startPrank(carol);
        asset.approve(address(vault), 10 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, carol, 10 * UNIT, 0));
        vault.deposit(10 * UNIT, carol);
        vm.stopPrank();
    }

    /// Finding V-07: a fee raise during a quarantine could be applied to profit that was earned at the old rate.
    function test_TheFeeCannotBeChangedDuringAQuarantine() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        vm.prank(mayor);
        vm.expectRevert(CityVault.QuarantineActive.selector);
        vault.setFee(1500);

        adapterA.setMode(0);
        vault.restoreAdapter(address(adapterA));
        vm.prank(mayor);
        vault.setFee(1500);
        assertEq(vault.feeBps(), 1500);
    }

    function test_CannotRebalanceIntoAQuarantinedAdapter() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.AdapterIsQuarantined.selector, address(adapterA)));
        vault.rebalance(address(0), address(adapterA), 10 * UNIT, bytes32(0));
    }

    /// With the quarantined position priced at zero, everyone is paid the same liquid price, so the order of exits does not
    /// matter and nobody can win a race. The price of that is documented: leavers give up their share of the frozen position.
    function test_EveryoneIsPaidTheSameLiquidPriceWhoeverLeavesFirst() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        // Liquid assets are 500 for 1000 shares-worth: a holder's exit is paid at half of the old claim.
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);

        uint256 aliceFirst;
        uint256 bobSecond;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        aliceFirst = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        bobSecond = vault.redeem(bobShares, bob, bob);
        assertApproxEqAbs(aliceFirst, 300 * UNIT, 2);
        assertApproxEqAbs(bobSecond, 200 * UNIT, 2);
        assertApproxEqAbs(aliceFirst + bobSecond, 500 * UNIT, 2, "all of the liquid assets and nothing more");

        vm.revertToState(snap);
        vm.prank(bob);
        uint256 bobFirst = vault.redeem(bobShares, bob, bob);
        vm.prank(alice);
        uint256 aliceSecond = vault.redeem(aliceShares, alice, alice);
        assertApproxEqAbs(bobFirst, bobSecond, 2);
        assertApproxEqAbs(aliceSecond, aliceFirst, 2);
    }

    function test_AHolderWhoWaitsGetsTheFrozenPositionBackAfterTheRestore() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob); // Bob leaves at the liquid price and gives up his part of A
        assertApproxEqAbs(asset.balanceOf(bob), 200 * UNIT, 2);

        adapterA.setMode(0);
        vault.restoreAdapter(address(adapterA));
        // Alice stayed: everything that is left is hers, the frozen position included (800 in total). What Bob gave up shows
        // up as a price rise above the high-water mark, so the mayor and the treasury take the usual 10% fee on it: 20.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 780 * UNIT, 4);
        vault.harvestFee();
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(mayor) + vault.balanceOf(treasury)), 20 * UNIT, 4);
    }

    function test_HealthyAdaptersStillWorkAndFeesStillAccrueWhileQuarantined() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        // The quarantine priced the city at 500 for shares that were minted at 1000, so profit has to climb back past the
        // high-water mark before any fee is due; a small gain therefore mints nothing, and nothing reverts.
        adapterB.addYield(20 * UNIT);
        vault.harvestFee();
        assertEq(vault.balanceOf(mayor), 0, "no fee while the price is below the high-water mark");
        vm.prank(mayor);
        vault.rebalance(address(adapterB), address(0), 50 * UNIT, bytes32(0));
    }

    function test_RestoreNeedsAnAdapterThatWorksAndThenEverythingReturnsToNormal() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));

        vm.expectRevert(abi.encodeWithSelector(CityVault.AdapterStillBroken.selector, address(adapterA)));
        vault.restoreAdapter(address(adapterA));
        vm.expectRevert(abi.encodeWithSelector(CityVault.NotQuarantined.selector, address(adapterB)));
        vault.restoreAdapter(address(adapterB));

        adapterA.setMode(0);
        adapterA.addYield(30 * UNIT); // it recovered, and earned something meanwhile
        vm.prank(stranger);
        vault.restoreAdapter(address(adapterA));
        assertFalse(vault.quarantined(address(adapterA)));
        assertEq(vault.quarantinedCount(), 0);
        assertEq(vault.totalAssets(), 1030 * UNIT, "valued at what it reports now");
        assertGt(vault.maxDeposit(carol), 0);
    }

    function test_ProbeTreatsGarbageReturnAndGasBurningAsBrokenWithoutBurningTheCaller() public {
        _fundedCity();
        adapterA.setMode(2); // returns a single byte
        vault.quarantine(address(adapterA));
        assertTrue(vault.quarantined(address(adapterA)));

        adapterB.setMode(3); // burns whatever gas it gets
        uint256 gasBefore = gasleft();
        vault.quarantine(address(adapterB));
        uint256 used = gasBefore - gasleft();
        assertTrue(vault.quarantined(address(adapterB)));
        assertLt(used, 1_300_000, "the probe is capped at 1M gas, so a gas-burning adapter cannot stall the call");
        assertEq(vault.quarantinedCount(), 2);
    }

    /// Finding V-05: an adapter that works but costs more gas than the quarantine probe allows could be quarantined by a
    /// stranger and then never restored. The restore probe is larger, so it comes back.
    function test_AnExpensiveButHealthyAdapterCanAlwaysBeRestored() public {
        _fundedCity();
        adapterA.setMode(4);
        vault.quarantine(address(adapterA)); // too expensive for the 1M-gas probe, so it counts as failing
        assertTrue(vault.quarantined(address(adapterA)));
        vault.restoreAdapter(address(adapterA));
        assertFalse(vault.quarantined(address(adapterA)));
        assertEq(vault.totalAssets(), 1000 * UNIT);
    }

    /// Finding V-04: an adapter whose withdrawal fails (but whose totalAssets works) used to block every withdrawal bigger
    /// than the idle cash, even when the other adapters could pay.
    function test_AnAdapterThatCannotWithdrawDoesNotBlockWithdrawalsTheOthersCanPay() public {
        _fundedCity();
        adapterA.setFailWithdraw(true);
        // 300 idle + 200 in adapter B can pay 450 although A (500) is stuck.
        vm.prank(bob);
        vault.withdraw(400 * UNIT, bob, bob);
        assertEq(asset.balanceOf(bob), 400 * UNIT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CityVault.InsufficientLiquidity.selector, 500 * UNIT));
        vault.withdraw(600 * UNIT, alice, alice);
    }

    function testFuzz_SameLiquidPriceForEveryoneWhoeverLeavesFirst(uint96 aliceIn, uint96 bobIn, uint96 toA, bool aliceFirst) public {
        aliceIn = uint96(bound(aliceIn, 10 * UNIT, 1_000_000 * UNIT));
        bobIn = uint96(bound(bobIn, 10 * UNIT, 1_000_000 * UNIT));
        _deposit(alice, aliceIn);
        _deposit(bob, bobIn);
        uint256 total = uint256(aliceIn) + bobIn;
        toA = uint96(bound(toA, 1, total / 2));
        _move(address(0), address(adapterA), toA);
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));

        uint256 liquid = total - toA;
        uint256 aShares = vault.balanceOf(alice);
        uint256 bShares = vault.balanceOf(bob);
        address first = aliceFirst ? alice : bob;
        address second = aliceFirst ? bob : alice;
        vm.prank(first);
        uint256 got1 = vault.redeem(aliceFirst ? aShares : bShares, first, first);
        vm.prank(second);
        uint256 got2 = vault.redeem(aliceFirst ? bShares : aShares, second, second);
        assertLe(got1 + got2, liquid, "never more than the liquid assets");
        assertApproxEqAbs(got1 + got2, liquid, 8, "and almost exactly all of them");
        // Each holder got their fraction of the liquid assets, in whichever order.
        uint256 aliceGot = aliceFirst ? got1 : got2;
        assertApproxEqAbs(aliceGot, (liquid * aShares) / (aShares + bShares), 8);
    }

    // ───────────────────────────── B1.10: session-key budget ─────────────────────────────

    function _sessionCity() internal {
        _deposit(alice, 1000 * UNIT);
        vm.prank(mayor);
        vault.setSessionKey(sessionKey, uint64(block.timestamp + 1 days), 5000);
    }

    function _keyMove(address from, address to, uint256 amount) internal {
        vm.prank(sessionKey);
        vault.rebalance(from, to, amount, bytes32(0));
    }

    function test_TheSessionKeyHasACumulativeHourlyBudgetOfTwentyPercentByDefault() public {
        _sessionCity();
        assertEq(vault.sessionBudgetBps(), 2000);
        _keyMove(address(0), address(adapterA), 100 * UNIT);
        _keyMove(address(0), address(adapterA), 100 * UNIT);
        vm.prank(sessionKey);
        vm.expectRevert(abi.encodeWithSelector(CityVault.SessionBudgetExceeded.selector, 201 * UNIT, 200 * UNIT));
        vault.rebalance(address(0), address(adapterA), 1 * UNIT, bytes32(0));
        // Three calls of 10% each could not move 30% any more.
        assertEq(vault.sessionWindowShifted(), 200 * UNIT);
    }

    function test_TheBudgetWindowRestartsAnHourAfterItOpened() public {
        _sessionCity();
        _keyMove(address(0), address(adapterA), 200 * UNIT);
        vm.warp(block.timestamp + 59 minutes);
        vm.prank(sessionKey);
        vm.expectRevert();
        vault.rebalance(address(0), address(adapterA), 1 * UNIT, bytes32(0));
        vm.warp(block.timestamp + 1 minutes);
        _keyMove(address(0), address(adapterB), 150 * UNIT);
        assertEq(vault.sessionWindowShifted(), 150 * UNIT);
    }

    function test_TheMayorAndApprovedProposalsAreNotLimitedByTheSessionBudget() public {
        _sessionCity();
        _keyMove(address(0), address(adapterA), 200 * UNIT);
        _move(address(0), address(adapterB), 400 * UNIT); // the mayor's own call, far over 20%, still within the per-call limit
        vm.prank(guardianAddr);
        vault.executeProposal(address(0), address(adapterA), 100 * UNIT, bytes32(0));
        assertEq(vault.sessionWindowShifted(), 200 * UNIT, "only the session key spends the budget");
    }

    function test_TheMayorCanSetTheBudgetAndANewSessionKeyStartsFresh() public {
        _sessionCity();
        _keyMove(address(0), address(adapterA), 200 * UNIT);
        vm.prank(mayor);
        vault.setSessionBudget(5000);
        _keyMove(address(0), address(adapterB), 300 * UNIT);

        vm.prank(mayor);
        vault.setSessionKey(sessionKey, uint64(block.timestamp + 1 days), 5000);
        assertEq(vault.sessionWindowShifted(), 0, "re-registering the key opens a new window");

        vm.prank(stranger);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setSessionBudget(10_000);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.BpsOutOfRange.selector, uint16(10_001)));
        vault.setSessionBudget(10_001);
    }

    // ───────────────────────────── style ─────────────────────────────

    function test_OnlyTheMayorSetsTheCityStyle() public {
        bytes32 code = bytes32("klasik.taman");
        vm.prank(stranger);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setStyle(code);
        vm.expectEmit(false, false, false, true);
        emit CityVault.StyleSet(code);
        vm.prank(mayor);
        vault.setStyle(code);
        assertEq(vault.style(), code);
    }
}
