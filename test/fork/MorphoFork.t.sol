// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {CityFactory} from "../../src/CityFactory.sol";
import {CityVault} from "../../src/CityVault.sol";
import {ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";

/// @notice Mainnet fork test for the R25 proof: a real city vault depositing into the real Morpho "Grove x Steakhouse
/// High Yield AUSD" vault (MetaMorpho V1) and coming back out. Skipped unless MONAD_MAINNET_RPC is set:
///   MONAD_MAINNET_RPC=https://rpc.monad.xyz forge test --match-contract MorphoForkTest -vv
/// `deal()` does not work for mainnet AUSD (S26 spike), so the depositor is funded by a transfer from Morpho Blue,
/// which holds millions of AUSD.
contract MorphoForkTest is Test {
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant GROVE = 0x32841A8511D5c2c5b253f45668780B99139e476D;
    address internal constant MORPHO_BLUE = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;
    uint256 internal constant CAP = 200e6; // the mainnet proof limit: 200 AUSD

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal guardianAddr = makeAddr("guardian");
    address internal mayor = makeAddr("mayor");
    address internal alice = makeAddr("alice");

    CityFactory internal factory;
    CityVault internal city;
    ERC4626Adapter internal adapter;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 143, "not Monad mainnet");
        assertEq(IERC4626(GROVE).asset(), AUSD, "target vault asset is not AUSD");

        factory = new CityFactory(owner, IERC20(AUSD), treasury, guardianAddr, CAP);
        ERC4626Adapter impl = new ERC4626Adapter();
        vm.startPrank(owner);
        factory.setAllowedAdapter(address(impl), true);
        factory.setAdapterParams(address(impl), abi.encode(GROVE));
        vm.stopPrank();

        address[] memory impls = new address[](1);
        impls[0] = address(impl);
        vm.prank(mayor);
        city = CityVault(factory.createCity("Mainnet proof", "", 1000, impls, ""));
        adapter = ERC4626Adapter(city.adapters()[0]);

        vm.prank(MORPHO_BLUE);
        IERC20(AUSD).transfer(alice, CAP);
        vm.prank(alice);
        IERC20(AUSD).approve(address(city), type(uint256).max);
    }

    function test_DepositRebalanceIntoMorphoAndWithdrawAll() public {
        // Deposit the whole cap; one unit more must be refused.
        vm.startPrank(alice);
        city.deposit(CAP, alice);
        vm.stopPrank();
        assertEq(city.totalAssets(), CAP);
        assertEq(city.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1, 0));
        city.deposit(1, alice);

        // Rebalance in two steps (max 50% per call). Morpho rounds the first deposit down by 1 wei, so total assets
        // are 199.999999 afterwards and the second step is exactly half of that, at the limit.
        vm.prank(mayor);
        city.rebalance(address(0), address(adapter), 100e6, keccak256("proof-1"));
        uint256 secondStep = city.totalAssets() / 2;
        vm.prank(mayor);
        city.rebalance(address(0), address(adapter), secondStep, keccak256("proof-2"));

        uint256 inMorpho = adapter.totalAssets();
        emit log_named_uint("assets in Morpho after deposit (expect ~200e6)", inMorpho);
        assertApproxEqAbs(inMorpho, CAP, 3, "Morpho rounding should cost at most a few wei");
        assertLe(IERC20(AUSD).balanceOf(address(city)), 2, "at most rounding dust stays idle");
        assertGt(IERC4626(GROVE).balanceOf(address(adapter)), 0);

        // Let a month of interest accrue in the real vault.
        vm.warp(block.timestamp + 30 days);
        uint256 later = adapter.totalAssets();
        emit log_named_uint("assets in Morpho after 30 days", later);
        assertGe(later, inMorpho, "the real vault should not lose value");

        // Pull half back to idle through the mayor, then everybody out.
        uint256 half = city.totalAssets() / 2;
        vm.prank(mayor);
        city.rebalance(address(adapter), address(0), half, keccak256("proof-3"));
        assertApproxEqAbs(IERC20(AUSD).balanceOf(address(city)), half, 3);

        uint256 shares = city.balanceOf(alice);
        vm.prank(alice);
        uint256 out = city.redeem(shares, alice, alice);
        emit log_named_uint("alice received", out);
        assertGe(out, CAP - 5, "resident gets back the deposit, minus at most dust");

        // Fee holders (mayor, treasury) can exit too, and the vault ends up empty up to dust.
        address[2] memory feeHolders = [mayor, treasury];
        for (uint256 i; i < feeHolders.length; ++i) {
            uint256 s = city.balanceOf(feeHolders[i]);
            if (s == 0) continue;
            vm.prank(feeHolders[i]);
            city.redeem(s, feeHolders[i], feeHolders[i]);
        }
        assertLe(city.totalAssets(), 5, "nothing meaningful is left behind");
    }

    function test_GuardianEvacuatesWholePositionToIdle() public {
        vm.prank(alice);
        city.deposit(CAP, alice);
        vm.prank(mayor);
        city.rebalance(address(0), address(adapter), 100e6, bytes32(0));
        uint256 positioned = adapter.totalAssets();
        assertGt(positioned, 0);

        vm.prank(guardianAddr);
        city.evacuate(address(adapter));

        assertEq(IERC4626(GROVE).balanceOf(address(adapter)), 0, "all Morpho shares redeemed");
        assertApproxEqAbs(IERC20(AUSD).balanceOf(address(city)), CAP, 3);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_AskingForSlightlyMoreThanTheRoundedPositionStillExits() public {
        // Depositing 100 leaves 99.999999 redeemable; asking the adapter for the nominal 100 must not revert.
        vm.prank(alice);
        city.deposit(CAP, alice);
        vm.prank(mayor);
        city.rebalance(address(0), address(adapter), 100e6, bytes32(0));

        vm.prank(address(city));
        uint256 got = adapter.withdraw(100e6);
        assertApproxEqAbs(got, 100e6, 3);
        assertEq(IERC4626(GROVE).balanceOf(address(adapter)), 0);
    }
}
