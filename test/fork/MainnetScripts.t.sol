// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DeployMainnet} from "../../script/DeployMainnet.s.sol";
import {MainnetProof} from "../../script/MainnetProof.s.sol";
import {CityVault} from "../../src/CityVault.sol";

/// @notice Dry run of the B4.8 mainnet scripts on a fork of Monad mainnet, with a throwaway key: deploy the capped
/// stack, found the city, deposit 20 AUSD, move it into the real Morpho vault, let a month pass, move it back and
/// redeem. Skipped unless MONAD_MAINNET_RPC is set. Nothing is sent to mainnet; the fork lives in memory.
contract MainnetScriptsTest is Test {
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant GROVE = 0x32841A8511D5c2c5b253f45668780B99139e476D;
    address internal constant MORPHO_BLUE = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;
    uint256 internal constant KEY = uint256(keccak256("mainnet-script-dry-run-throwaway"));
    uint256 internal constant AMOUNT = 20e6;

    address internal wallet;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 143, "not Monad mainnet");

        wallet = vm.addr(KEY);
        vm.deal(wallet, 10 ether);
        vm.prank(MORPHO_BLUE);
        IERC20(AUSD).transfer(wallet, 50e6);
    }

    function _deploy(uint256 cap) internal returns (DeployMainnet.Deployment memory) {
        return new DeployMainnet().deploy(KEY, wallet, wallet, cap, "Nusastakes mainnet proof", 1000);
    }

    function test_DeployFoundCityDepositInvestAndWithdraw() public {
        DeployMainnet.Deployment memory d = _deploy(200e6);
        assertEq(d.factory.depositCap(), 200e6);
        assertEq(d.city.mayor(), wallet);
        assertEq(d.factory.owner(), wallet);
        assertTrue(d.factory.allowedAdapterImpl(address(d.adapterImpl)));

        MainnetProof proof = new MainnetProof();
        proof.execute(KEY, d.city, "in", AMOUNT);

        address adapter = d.city.adapters()[0];
        assertApproxEqAbs(CityVault(address(d.city)).totalAssets(), AMOUNT, 3);
        assertApproxEqAbs(IERC4626(adapter).totalAssets(), AMOUNT, 5, "almost everything is in Morpho");
        assertEq(IERC20(AUSD).balanceOf(wallet), 50e6 - AMOUNT);

        vm.warp(block.timestamp + 30 days);
        proof.execute(KEY, d.city, "out", 0);

        assertEq(IERC20(GROVE).balanceOf(adapter), 0, "no Morpho shares left");
        assertGe(IERC20(AUSD).balanceOf(wallet), 50e6 - 5, "the wallet is made whole, up to rounding dust");
        assertEq(d.city.balanceOf(wallet), 0);
    }

    function test_CapAboveTwoHundredAusdIsRefused() public {
        DeployMainnet script = new DeployMainnet();
        vm.expectRevert("DEPOSIT_CAP must be between 1 and 200 AUSD (6 decimals)");
        script.deploy(KEY, wallet, wallet, 201e6, "too big", 1000);
    }

    function test_ProofRefusesAmountsAboveTheCap() public {
        DeployMainnet.Deployment memory d = _deploy(200e6);
        MainnetProof script = new MainnetProof();
        vm.expectRevert("AMOUNT must be between 1 and 200 AUSD (6 decimals)");
        script.execute(KEY, d.city, "in", 201e6);
    }
}
