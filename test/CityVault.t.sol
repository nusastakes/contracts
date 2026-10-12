// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {BaseTest} from "./Base.t.sol";
import {CityVault} from "../src/CityVault.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

contract CityVaultTest is BaseTest {
    event Rebalanced(
        address indexed caller, address indexed from, address indexed to, uint256 amount, bytes32 planHash
    );
    event Evacuated(address indexed adapter, uint256 amount);
    event DeputySet(address indexed deputy, uint64 expiry, uint16 maxShiftBps);
    event PlanKeyRevealed(bytes32 indexed entryId, bytes32 key);

    // ------------------------------------------------------------------ 1. deposit and redeem

    function test_DepositThenRedeemReturnsSameAssets() public {
        uint256 shares = _deposit(alice, 1000 * UNIT);
        assertEq(vault.totalAssets(), 1000 * UNIT);
        assertEq(vault.decimals(), 12);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertEq(out, 1000 * UNIT);
        assertEq(asset.balanceOf(alice), 1000 * UNIT);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_WithdrawExactAssets() public {
        _deposit(alice, 1000 * UNIT);
        vm.prank(alice);
        vault.withdraw(400 * UNIT, alice, alice);
        assertEq(asset.balanceOf(alice), 400 * UNIT);
        assertApproxEqAbs(_assetsOf(alice), 600 * UNIT, 1);
    }

    function test_MintPullsMatchingAssets() public {
        asset.mint(alice, 1000 * UNIT);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        uint256 assetsIn = vault.mint(500 * UNIT * UNIT, alice);
        vm.stopPrank();
        assertEq(assetsIn, 500 * UNIT);
        assertEq(vault.balanceOf(alice), 500 * UNIT * UNIT);
    }

    // ------------------------------------------------------------------ 2. inflation attack

    function test_InflationAttackFails() public {
        // Attacker is first in, with the smallest possible deposit, then donates directly to the vault.
        _deposit(bob, 1);
        asset.mint(bob, 10_000 * UNIT);
        vm.prank(bob);
        asset.transfer(address(vault), 10_000 * UNIT);

        // Victim deposits the same size as the donation.
        uint256 victimShares = _deposit(carol, 10_000 * UNIT);
        assertGt(victimShares, 0);

        vm.prank(carol);
        uint256 victimOut = vault.redeem(victimShares, carol, carol);
        // With a 6-digit decimals offset the victim can lose at most about one share unit, which is worth
        // donation / 2e6 here (about 0.005 AUSD on a 10,000 AUSD deposit). Without the offset the loss would be ~50%.
        assertGe(victimOut, 10_000 * UNIT - 10_000, "victim lost more than one share unit of rounding");

        uint256 attackerShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 attackerOut = vault.redeem(attackerShares, bob, bob);
        // The attacker put in 10_000 * UNIT + 1 and gets back far less.
        assertLt(attackerOut, 10_000 * UNIT / 2 + 10, "attacker should lose about half of the donation");
    }

    // ------------------------------------------------------------------ 3. fee with high-water mark

    function _seedWithYield(uint256 yieldAmount) internal {
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        adapterA.addYield(yieldAmount);
    }

    function test_NoFeeWithoutProfit() public {
        _deposit(alice, 1000 * UNIT);
        uint256 supplyBefore = vault.totalSupply();
        vault.harvestFee();
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.balanceOf(mayor), 0);
        assertEq(vault.balanceOf(treasury), 0);
    }

    function test_FeeIsTenPercentOfProfitSplitNinetyTen() public {
        _seedWithYield(100 * UNIT);
        vault.harvestFee();

        // Profit 100 -> fee 10 -> mayor 9, platform 1. Residents keep 1090.
        assertApproxEqAbs(_assetsOf(alice), 1090 * UNIT, 5);
        assertApproxEqAbs(_assetsOf(mayor), 9 * UNIT, 5);
        assertApproxEqAbs(_assetsOf(treasury), 1 * UNIT, 5);

        uint256 mayorShares = vault.balanceOf(mayor);
        uint256 treasuryShares = vault.balanceOf(treasury);
        assertEq(
            treasuryShares, (mayorShares + treasuryShares) * 1000 / 10_000, "platform gets exactly 10% of fee shares"
        );
    }

    function test_FeeNotChargedTwiceForSameProfit() public {
        _seedWithYield(100 * UNIT);
        vault.harvestFee();
        uint256 supply = vault.totalSupply();
        vault.harvestFee();
        _deposit(bob, 100 * UNIT); // deposits accrue first too
        assertEq(vault.totalSupply() - supply, vault.balanceOf(bob), "no new fee shares, only bob's");
    }

    function test_NoFeeOnLossAndNoFeeUntilPreviousHighIsBeaten() public {
        _seedWithYield(100 * UNIT);
        vault.harvestFee();
        uint256 supplyAtHigh = vault.totalSupply();

        // Lose 200, nothing to charge.
        adapterA.lose(200 * UNIT);
        vault.harvestFee();
        assertEq(vault.totalSupply(), supplyAtHigh, "no fee on loss");

        // Recover exactly to the previous high: still nothing.
        adapterA.addYield(200 * UNIT);
        vault.harvestFee();
        assertEq(vault.totalSupply(), supplyAtHigh, "no fee for merely recovering");

        // Beat the previous high by 50: fee only on those 50, i.e. 5.
        adapterA.addYield(50 * UNIT);
        vault.harvestFee();
        uint256 minted = vault.totalSupply() - supplyAtHigh;
        assertGt(minted, 0);
        assertApproxEqAbs(vault.convertToAssets(minted), 5 * UNIT, 10);
    }

    function test_RaisingFeeLaterDoesNotChargeOldProfit() public {
        // City with 0% fee earns 100, then the mayor raises the fee: old profit stays fee-free.
        vault = _createCity(mayor, 0);
        address[] memory list = vault.adapters();
        adapterA = MockYieldAdapter(list[0]);
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        adapterA.addYield(100 * UNIT);

        vm.prank(mayor);
        vault.setFee(2000);
        uint256 supply = vault.totalSupply();
        vault.harvestFee();
        assertEq(vault.totalSupply(), supply, "profit made at 0% fee is not charged retroactively");
    }

    function test_SetFeeCrystallisesPendingFeeAtOldRate() public {
        _seedWithYield(100 * UNIT);
        vm.prank(mayor);
        vault.setFee(0);
        // Pending 10% on the 100 profit was minted before the rate changed.
        assertApproxEqAbs(_assetsOf(mayor) + _assetsOf(treasury), 10 * UNIT, 10);
        assertEq(vault.feeBps(), 0);
    }

    function test_FeeCannotExceedFactoryMax() public {
        assertEq(factory.maxFeeBps(), 2000);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.FeeTooHigh.selector, uint16(2001), uint16(2000)));
        vault.setFee(2001);

        address[] memory none = new address[](0);
        vm.prank(mayor);
        vm.expectRevert();
        factory.createCity("Too greedy", "", 2001, none, "");
    }

    function test_PreviewsAreNetOfPendingFeeAndNeverOptimistic() public {
        _seedWithYield(100 * UNIT);
        uint256 shares = vault.balanceOf(alice);
        uint256 previewed = vault.previewRedeem(shares);
        assertGt(vault.pendingFeeShares(), 0);
        assertApproxEqAbs(previewed, 1090 * UNIT, 5);

        vm.prank(alice);
        uint256 paid = vault.redeem(shares, alice, alice);
        assertLe(paid, previewed + 1, "redeem pays no more than previewRedeem promised");
        assertApproxEqAbs(paid, previewed, 2);
        assertEq(vault.pendingFeeShares(), 0);
    }

    function test_NewDepositorDoesNotPayFeeOnProfitEarnedBeforeThem() public {
        _seedWithYield(100 * UNIT);
        // Bob deposits before anybody called harvestFee. Accrual runs first, so he only bears fees he is exposed to.
        _deposit(bob, 1090 * UNIT);
        assertApproxEqAbs(_assetsOf(bob), 1090 * UNIT, 5);
    }

    // ------------------------------------------------------------------ 4. rebalance rules

    function test_RebalanceMovesIdleToAdapterAndBack() public {
        _deposit(alice, 1000 * UNIT);
        bytes32 plan = keccak256("plan-1");

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(mayor, address(0), address(adapterA), 500 * UNIT, plan);
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterA), 500 * UNIT, plan);

        assertEq(adapterA.totalAssets(), 500 * UNIT);
        assertEq(asset.balanceOf(address(vault)), 500 * UNIT);
        assertEq(vault.totalAssets(), 1000 * UNIT);

        _move(address(adapterA), address(adapterB), 300 * UNIT);
        assertEq(adapterA.totalAssets(), 200 * UNIT);
        assertEq(adapterB.totalAssets(), 300 * UNIT);

        _move(address(adapterB), address(0), 300 * UNIT);
        assertEq(adapterB.totalAssets(), 0);
        assertEq(asset.balanceOf(address(vault)), 800 * UNIT);
    }

    function test_RebalanceRevertsForAdapterOfAnotherCity() public {
        _deposit(alice, 1000 * UNIT);
        CityVault other = _createCity(bob, 500);
        address foreign = other.adapters()[0];

        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.UnknownAdapter.selector, foreign));
        vault.rebalance(address(0), foreign, 100 * UNIT, bytes32(0));

        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.UnknownAdapter.selector, makeAddr("random")));
        vault.rebalance(makeAddr("random"), address(0), 100 * UNIT, bytes32(0));
    }

    function test_RebalanceRevertsAboveMaxShift() public {
        _deposit(alice, 1000 * UNIT);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.ShiftTooHigh.selector, 500 * UNIT + 1, 500 * UNIT));
        vault.rebalance(address(0), address(adapterA), 500 * UNIT + 1, bytes32(0));

        // The mayor can tighten the limit, and cannot loosen it past 100%.
        vm.startPrank(mayor);
        vault.setMaxShift(1000);
        vm.expectRevert(abi.encodeWithSelector(CityVault.ShiftTooHigh.selector, 100 * UNIT + 1, 100 * UNIT));
        vault.rebalance(address(0), address(adapterA), 100 * UNIT + 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(CityVault.BpsOutOfRange.selector, uint16(10_001)));
        vault.setMaxShift(10_001);
        vm.stopPrank();
    }

    function test_RebalanceRevertsOnBadArguments() public {
        _deposit(alice, 1000 * UNIT);
        vm.startPrank(mayor);
        vm.expectRevert(CityVault.ZeroAmount.selector);
        vault.rebalance(address(0), address(adapterA), 0, bytes32(0));
        vm.expectRevert(CityVault.SameAdapter.selector);
        vault.rebalance(address(adapterA), address(adapterA), 1, bytes32(0));
        vm.expectRevert(CityVault.SameAdapter.selector);
        vault.rebalance(address(0), address(0), 1, bytes32(0));
        vm.stopPrank();
    }

    function test_RebalanceFromIdleRevertsWhenIdleTooSmall() public {
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        // Idle is 500; moving 500 more would also exceed 50% only if above 500, so ask for exactly the idle plus one.
        vm.prank(mayor);
        vm.expectRevert();
        vault.rebalance(address(0), address(adapterB), 501 * UNIT, bytes32(0));
    }

    function test_OnlyMayorOrDeputyMayRebalance() public {
        _deposit(alice, 1000 * UNIT);
        vm.prank(alice);
        vm.expectRevert(CityVault.NotAuthorizedToRebalance.selector);
        vault.rebalance(address(0), address(adapterA), 100 * UNIT, bytes32(0));
    }

    function test_RebalanceCannotSendAssetsAnywhereButAdapters() public {
        // Direct check of the central safety claim: after any rebalance the only places assets can be are the
        // vault itself and this city's adapters.
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        _move(address(adapterA), address(adapterB), 250 * UNIT);
        assertEq(
            asset.balanceOf(address(vault)) + asset.balanceOf(address(adapterA)) + asset.balanceOf(address(adapterB)),
            1000 * UNIT
        );
        assertEq(asset.balanceOf(mayor), 0);
    }

    // ------------------------------------------------------------------ 5. deputy

    function _setDeputy(uint64 expiry, uint16 shiftBps) internal {
        vm.prank(mayor);
        vault.setDeputy(deputy, expiry, shiftBps);
    }

    function test_DeputyCanRebalanceWithinOwnLimit() public {
        _deposit(alice, 1000 * UNIT);
        _setDeputy(uint64(block.timestamp + 1 days), 2000);

        vm.prank(deputy);
        vault.rebalance(address(0), address(adapterA), 200 * UNIT, keccak256("deputy"));
        assertEq(adapterA.totalAssets(), 200 * UNIT);

        vm.prank(deputy);
        vm.expectRevert(abi.encodeWithSelector(CityVault.ShiftTooHigh.selector, 200 * UNIT + 1, 200 * UNIT));
        vault.rebalance(address(0), address(adapterA), 200 * UNIT + 1, bytes32(0));
    }

    function test_DeputyLimitIsCappedByMayorMaxShift() public {
        _deposit(alice, 1000 * UNIT);
        vm.startPrank(mayor);
        vault.setMaxShift(1000);
        vault.setDeputy(deputy, uint64(block.timestamp + 1 days), 9000);
        vm.stopPrank();

        vm.prank(deputy);
        vm.expectRevert(abi.encodeWithSelector(CityVault.ShiftTooHigh.selector, 100 * UNIT + 1, 100 * UNIT));
        vault.rebalance(address(0), address(adapterA), 100 * UNIT + 1, bytes32(0));
    }

    function test_DeputyFailsAfterExpiry() public {
        _deposit(alice, 1000 * UNIT);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        _setDeputy(expiry, 5000);

        vm.warp(expiry - 1);
        vm.prank(deputy);
        vault.rebalance(address(0), address(adapterA), 100 * UNIT, bytes32(0));

        vm.warp(expiry);
        vm.prank(deputy);
        vm.expectRevert(CityVault.NotAuthorizedToRebalance.selector);
        vault.rebalance(address(0), address(adapterA), 100 * UNIT, bytes32(0));
    }

    function test_DeputyCannotCallAnythingExceptRebalance() public {
        _deposit(alice, 1000 * UNIT);
        _setDeputy(uint64(block.timestamp + 1 days), 5000);

        vm.startPrank(deputy);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setFee(0);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setMaxShift(10_000);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setDeputy(deputy, uint64(block.timestamp + 10 days), 10_000);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.revealPlanKey(bytes32(uint256(1)), bytes32(uint256(2)));
        vm.expectRevert(CityVault.NotGuardian.selector);
        vault.evacuate(address(adapterA));
        vm.expectRevert(CityVault.NotGuardian.selector);
        vault.executeProposal(address(0), address(adapterA), 1, bytes32(0));
        vm.stopPrank();
    }

    function test_DeputyCannotWithdrawOtherPeoplesShares() public {
        uint256 shares = _deposit(alice, 1000 * UNIT);
        _setDeputy(uint64(block.timestamp + 1 days), 5000);

        vm.startPrank(deputy);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deputy, 0, shares));
        vault.redeem(shares, deputy, alice);
        uint256 sharesFor1 = vault.previewWithdraw(1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deputy, 0, sharesFor1));
        vault.withdraw(1, deputy, alice);
        vm.stopPrank();
        assertEq(asset.balanceOf(deputy), 0);
    }

    function test_SetDeputyValidationAndRemoval() public {
        vm.startPrank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.ExpiryInPast.selector, uint64(block.timestamp)));
        vault.setDeputy(deputy, uint64(block.timestamp), 1000);
        vm.expectRevert(abi.encodeWithSelector(CityVault.BpsOutOfRange.selector, uint16(10_001)));
        vault.setDeputy(deputy, uint64(block.timestamp + 1 days), 10_001);

        vm.expectEmit(true, false, false, true);
        emit DeputySet(deputy, uint64(block.timestamp + 1 days), 1000);
        vault.setDeputy(deputy, uint64(block.timestamp + 1 days), 1000);
        assertEq(vault.deputy(), deputy);

        vault.setDeputy(address(0), 0, 0);
        vm.stopPrank();
        assertEq(vault.deputy(), address(0));

        _deposit(alice, 1000 * UNIT);
        vm.prank(deputy);
        vm.expectRevert(CityVault.NotAuthorizedToRebalance.selector);
        vault.rebalance(address(0), address(adapterA), 1, bytes32(0));
    }

    function test_ZeroAddressIsNeverADeputy() public {
        _deposit(alice, 1000 * UNIT);
        vm.prank(address(0));
        vm.expectRevert(CityVault.NotAuthorizedToRebalance.selector);
        vault.rebalance(address(0), address(adapterA), 1, bytes32(0));
    }

    // ------------------------------------------------------------------ 6. evacuate

    function test_OnlyGuardianCanEvacuateAndFundsGoToIdle() public {
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        adapterA.addYield(50 * UNIT);

        vm.prank(mayor);
        vm.expectRevert(CityVault.NotGuardian.selector);
        vault.evacuate(address(adapterA));

        vm.expectEmit(true, false, false, true);
        emit Evacuated(address(adapterA), 550 * UNIT);
        vm.prank(guardianAddr);
        vault.evacuate(address(adapterA));

        assertEq(adapterA.totalAssets(), 0);
        assertEq(asset.balanceOf(address(vault)), 1050 * UNIT);
        assertEq(asset.balanceOf(guardianAddr), 0, "evacuation never pays the guardian");
    }

    function test_EvacuateRejectsForeignAdapter() public {
        CityVault other = _createCity(bob, 500);
        address foreign = other.adapters()[0];
        vm.prank(guardianAddr);
        vm.expectRevert(abi.encodeWithSelector(CityVault.UnknownAdapter.selector, foreign));
        vault.evacuate(foreign);
    }

    // ------------------------------------------------------------------ 8. depositWithPermit

    function test_DepositWithPermitMintsToSignerNotRelayer() public {
        asset.mint(alice, 500 * UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, alice, address(vault), 500 * UNIT, deadline);

        vm.prank(relayer);
        uint256 shares = vault.depositWithPermit(alice, 500 * UNIT, deadline, v, r, s);

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(relayer), 0);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 500 * UNIT);
        assertEq(asset.allowance(alice, address(vault)), 0, "allowance fully used");
    }

    function test_DepositWithPermitSucceedsIfPermitWasAlreadySubmittedByAnotherParty() public {
        asset.mint(alice, 500 * UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, alice, address(vault), 500 * UNIT, deadline);

        // A front-runner submits the same permit first.
        vm.prank(bob);
        asset.permit(alice, address(vault), 500 * UNIT, deadline, v, r, s);

        vm.prank(relayer);
        uint256 shares = vault.depositWithPermit(alice, 500 * UNIT, deadline, v, r, s);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(bob) + vault.balanceOf(relayer), 0);
    }

    function test_DepositWithPermitFailsWithBadSignatureAndNoAllowance() public {
        asset.mint(alice, 500 * UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, alice, address(vault), 500 * UNIT, deadline);

        vm.prank(relayer);
        // Signature was for 500; claiming 600 makes it invalid, and there is no allowance to fall back on.
        vm.expectRevert();
        vault.depositWithPermit(alice, 600 * UNIT, deadline, v, r, s);
        assertEq(asset.balanceOf(alice), 500 * UNIT);
    }

    function test_StandingAllowanceCannotBeUsedToForceADeposit() public {
        asset.mint(alice, 1000 * UNIT);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        // Bob has no valid signature, only alice's existing unlimited approval to the vault to lean on.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CityVault.PermitNotHonoured.selector, alice));
        vault.depositWithPermit(
            alice, 500 * UNIT, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2))
        );
        assertEq(asset.balanceOf(alice), 1000 * UNIT, "nothing moved");
        assertEq(vault.totalSupply(), 0);
    }

    function test_OwnerCanStillDepositThroughThePermitFunctionWithAStandingAllowance() public {
        asset.mint(alice, 1000 * UNIT);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        uint256 shares = vault.depositWithPermit(alice, 500 * UNIT, block.timestamp, 0, bytes32(0), bytes32(0));
        assertEq(vault.balanceOf(alice), shares);
        assertEq(asset.balanceOf(alice), 500 * UNIT);
    }

    function test_DepositWithPermitFailsAfterDeadline() public {
        asset.mint(alice, 500 * UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, alice, address(vault), 500 * UNIT, deadline);
        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert();
        vault.depositWithPermit(alice, 500 * UNIT, deadline, v, r, s);
    }

    function test_DepositWithPermitRespectsDepositCap() public {
        vm.prank(owner);
        factory.setDepositCap(100 * UNIT);
        vault = _createCity(mayor, 1000);

        asset.mint(alice, 500 * UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, alice, address(vault), 500 * UNIT, deadline);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 500 * UNIT, 100 * UNIT)
        );
        vault.depositWithPermit(alice, 500 * UNIT, deadline, v, r, s);
    }

    // ------------------------------------------------------------------ 9. withdrawals pull from adapters

    function test_WithdrawPullsFromAdaptersWhenIdleIsShort() public {
        uint256 shares = _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        _move(address(0), address(adapterB), 250 * UNIT);
        // idle 250, A 500, B 250

        vm.prank(alice);
        vault.withdraw(400 * UNIT, alice, alice); // 250 idle + 150 from A
        assertEq(asset.balanceOf(alice), 400 * UNIT);
        assertEq(adapterA.totalAssets(), 350 * UNIT);
        assertEq(adapterB.totalAssets(), 250 * UNIT);

        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(rest, alice, alice); // everything else, from both adapters
        assertEq(asset.balanceOf(alice), 1000 * UNIT);
        assertEq(vault.totalAssets(), 0);
        assertGt(shares, 0);
    }

    function test_WithdrawIncludesYieldHeldInAdapters() public {
        _deposit(alice, 1000 * UNIT);
        _move(address(0), address(adapterA), 500 * UNIT);
        adapterA.addYield(100 * UNIT);

        uint256 aliceClaim = _assetsOf(alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        // The view already showed alice's claim net of the pending fee, so it matches what is paid out.
        assertApproxEqAbs(aliceClaim, 1090 * UNIT, 5);
        assertApproxEqAbs(asset.balanceOf(alice), aliceClaim, 5);
        assertGt(asset.balanceOf(alice), 1000 * UNIT, "yield reached the resident");
    }

    // ------------------------------------------------------------------ deposit cap

    function test_DepositCapBlocksDepositsOverTheLimit() public {
        vm.prank(owner);
        factory.setDepositCap(1000 * UNIT);
        vault = _createCity(mayor, 1000);

        _deposit(alice, 1000 * UNIT);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);

        asset.mint(bob, 1);
        vm.startPrank(bob);
        asset.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1, 0));
        vault.deposit(1, bob);
        vm.stopPrank();

        // Withdrawals are never blocked, and free up room.
        vm.prank(alice);
        vault.withdraw(100 * UNIT, alice, alice);
        assertEq(vault.maxDeposit(bob), 100 * UNIT);
    }

    function test_DepositCapCountsYieldInAdapters() public {
        vm.prank(owner);
        factory.setDepositCap(1000 * UNIT);
        vault = _createCity(mayor, 1000);
        address[] memory list = vault.adapters();
        adapterA = MockYieldAdapter(list[0]);

        _deposit(alice, 900 * UNIT);
        _move(address(0), address(adapterA), 400 * UNIT);
        adapterA.addYield(60 * UNIT);
        assertEq(vault.maxDeposit(bob), 40 * UNIT);
    }

    function test_LoweringTheCapNeverTrapsExistingDepositors() public {
        _deposit(alice, 1000 * UNIT);
        vm.prank(owner);
        factory.setDepositCap(0);
        assertEq(vault.maxDeposit(bob), 0);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(asset.balanceOf(alice), 1000 * UNIT);
    }

    function test_MaxMintStaysWithinCap() public {
        vm.prank(owner);
        factory.setDepositCap(1000 * UNIT);
        vault = _createCity(mayor, 1000);
        _deposit(alice, 400 * UNIT);

        uint256 maxShares = vault.maxMint(bob);
        assertLe(vault.previewMint(maxShares), vault.maxDeposit(bob));
    }

    // ------------------------------------------------------------------ misc

    function test_RevealPlanKeyOnlyEmits() public {
        _deposit(alice, 1000 * UNIT);
        uint256 total = vault.totalAssets();
        vm.expectEmit(true, false, false, true);
        emit PlanKeyRevealed(bytes32(uint256(7)), bytes32(uint256(99)));
        vm.prank(mayor);
        vault.revealPlanKey(bytes32(uint256(7)), bytes32(uint256(99)));
        assertEq(vault.totalAssets(), total);

        vm.prank(alice);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.revealPlanKey(bytes32(uint256(7)), bytes32(uint256(99)));
    }

    function test_InitAdaptersOnlyFactoryAndOnlyOnce() public {
        address[] memory list = new address[](0);
        vm.prank(mayor);
        vm.expectRevert(CityVault.NotFactory.selector);
        vault.initAdapters(list);

        vm.prank(address(factory));
        vm.expectRevert(CityVault.AdaptersAlreadySet.selector);
        vault.initAdapters(list);
    }

    function test_VaultMetadata() public view {
        assertEq(vault.mayor(), mayor);
        assertEq(vault.factory(), address(factory));
        assertEq(vault.guardian(), guardianAddr);
        assertEq(vault.platformCutBps(), 1000);
        assertEq(vault.feeBps(), 1000);
        assertEq(vault.maxShiftBps(), 5000);
        assertEq(vault.asset(), address(asset));
        assertEq(vault.name(), "Jakarta");
        assertTrue(factory.isCity(address(vault)));
        assertEq(vault.adapters().length, 2);
    }
}
