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
        assertEq(vault.totalAssets(), 1000 * UNIT, "the broken adapter counts at its last known value");

        vm.expectRevert(abi.encodeWithSelector(CityVault.AlreadyQuarantined.selector, address(adapterA)));
        vault.quarantine(address(adapterA));
    }

    function test_FrozenValueIsTheLastOneSeenByAStateChangingCall() public {
        _fundedCity();
        adapterA.addYield(50 * UNIT);
        vault.harvestFee(); // a state-changing call records the new value
        assertEq(vault.lastKnownAssets(address(adapterA)), 550 * UNIT);
        uint256 priceBefore = vault.pricePerShare();

        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        assertEq(vault.totalAssets(), 1050 * UNIT);
        assertEq(vault.pricePerShare(), priceBefore, "the share price does not jump when the adapter is frozen");
    }

    function test_ARebalanceRecordsTheNewValueSoAQuarantineRightAfterIsExact() public {
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 400 * UNIT);
        assertEq(vault.lastKnownAssets(address(adapterA)), 400 * UNIT);
        _move(address(adapterA), address(0), 100 * UNIT);
        assertEq(vault.lastKnownAssets(address(adapterA)), 300 * UNIT);
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        assertEq(vault.totalAssets(), 1000 * UNIT);
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

    function test_CannotRebalanceIntoAQuarantinedAdapter() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.AdapterIsQuarantined.selector, address(adapterA)));
        vault.rebalance(address(0), address(adapterA), 10 * UNIT, bytes32(0));
    }

    function test_WithdrawalsAreCappedAtEachHoldersShareOfTheLiquidAssets() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        // Liquid = 300 idle + 200 in adapter B = 500. Alice holds 60%, Bob 40%.
        assertEq(vault.maxWithdraw(alice), 300 * UNIT);
        assertEq(vault.maxWithdraw(bob), 200 * UNIT);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(300 * UNIT + 1, alice, alice);

        vm.prank(alice);
        vault.withdraw(300 * UNIT, alice, alice);
        assertEq(asset.balanceOf(alice), 300 * UNIT);
        // Alice kept shares worth 300 that still sit on the frozen position, so what is liquid now (200) is shared
        // between her remaining shares and Bob's: Bob's cap is his fraction of the remaining supply times 200.
        assertApproxEqAbs(vault.maxWithdraw(bob), (200 * UNIT * 400) / 700, 2);
        assertLe(vault.maxWithdraw(alice) + vault.maxWithdraw(bob), 200 * UNIT, "the caps never add up to more than is liquid");
    }

    /// Repeated exits by both holders converge on the whole liquid amount and never pass it.
    function test_RepeatedExitsNeverExceedWhatWasLiquid() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        uint256 out;
        for (uint256 round; round < 40; ++round) {
            address who = round % 2 == 0 ? alice : bob;
            uint256 cap = vault.maxWithdraw(who);
            if (cap == 0) continue;
            vm.prank(who);
            vault.withdraw(cap, who, who);
            out += cap;
            assertLe(out, 500 * UNIT, "never more than the liquid assets that existed");
        }
        assertGt(out, 480 * UNIT, "and they get almost all of it in the end");
        assertEq(vault.lastKnownAssets(address(adapterA)), 500 * UNIT, "the frozen position is untouched");
    }

    function test_RedeemIsCappedTheSameWayAndSkipsTheBrokenAdapter() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        uint256 shares = vault.maxRedeem(bob);
        assertLt(shares, vault.balanceOf(bob), "Bob cannot redeem every share while 500 sits in the frozen adapter");
        vm.prank(bob);
        uint256 got = vault.redeem(shares, bob, bob);
        assertApproxEqAbs(got, 200 * UNIT, 2);
        assertApproxEqAbs(asset.balanceOf(address(vault)) + adapterB.totalAssets(), 500 * UNIT - got, 2);
    }

    function test_HealthyAdaptersStillWorkAndFeesStillAccrueWhileQuarantined() public {
        _fundedCity();
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));
        adapterB.addYield(20 * UNIT);
        vault.harvestFee(); // does not revert with a quarantined adapter around
        assertGt(vault.balanceOf(mayor), 0, "the mayor earned a fee on adapter B's profit");
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
        assertEq(vault.lastKnownAssets(address(adapterA)), 530 * UNIT);
        assertEq(vault.totalAssets(), 1030 * UNIT, "valued at what it reports now");
        assertEq(vault.maxDeposit(carol) > 0, true);
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice), "no pro-rata cap any more");
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

    function testFuzz_NoHolderCanTakeMoreThanTheirShareOfTheLiquidAssets(uint96 aliceIn, uint96 bobIn, uint96 toA, uint96 toB, uint96 pull) public {
        aliceIn = uint96(bound(aliceIn, 10 * UNIT, 1_000_000 * UNIT));
        bobIn = uint96(bound(bobIn, 10 * UNIT, 1_000_000 * UNIT));
        _deposit(alice, aliceIn);
        _deposit(bob, bobIn);
        uint256 total = uint256(aliceIn) + bobIn;
        toA = uint96(bound(toA, 0, total / 2));
        toB = uint96(bound(toB, 0, total / 2));
        if (toA > 0) _move(address(0), address(adapterA), toA);
        if (toB > 0) _move(address(0), address(adapterB), toB);
        adapterA.setMode(1);
        vault.quarantine(address(adapterA));

        uint256 liquid = total - toA;
        uint256 aliceMax = vault.maxWithdraw(alice);
        uint256 bobMax = vault.maxWithdraw(bob);
        assertLe(aliceMax + bobMax, liquid, "the two caps never add up to more than what is liquid");
        pull = uint96(bound(pull, 0, aliceMax));
        if (pull > 0) {
            vm.prank(alice);
            vault.withdraw(pull, alice, alice);
        }
        uint256 liquidNow = liquid - pull;
        assertLe(vault.maxWithdraw(bob), liquidNow, "Bob can never take more than what is still liquid");
        assertLe(vault.maxWithdraw(bob) + vault.maxWithdraw(alice), liquidNow);
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
