// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CityVault} from "../src/CityVault.sol";
import {IAdapter} from "../src/interfaces/IAdapter.sol";

/// @notice The two halves of the R25 mainnet proof, run against the city that DeployMainnet.s.sol created. The wallet
/// must be the city's mayor and hold the AUSD (the plan budgets 20 to 50 AUSD, the city refuses more than 200).
///
///   PHASE=in  AMOUNT=20000000 CITY=0x… forge script script/MainnetProof.s.sol --rpc-url $MONAD_MAINNET_RPC --broadcast
///   PHASE=out CITY=0x…                forge script script/MainnetProof.s.sol --rpc-url $MONAD_MAINNET_RPC --broadcast
///
/// `in` approves, deposits AMOUNT (6 decimals: 20000000 is 20 AUSD) and moves it into the Morpho vault in as many
/// rebalances as the city's per-call limit needs. `out` moves it back to idle and redeems every share of the wallet.
/// Run `out` some time after `in` so the real vault has accrued a little interest. Without `--broadcast` both only
/// simulate. Uses MAINNET_DEPLOYER_PRIVATE_KEY, never the testnet key.
contract MainnetProof is Script {
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_STEPS = 6;

    function run() external {
        string memory phase = vm.envString("PHASE");
        // AMOUNT is only needed by the `in` phase.
        execute(vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY"), CityVault(vm.envAddress("CITY")), phase, vm.envOr("AMOUNT", uint256(0)));
    }

    /// @dev Public so the fork test can call it with explicit arguments instead of process-wide environment variables.
    function execute(uint256 key, CityVault city, string memory phase, uint256 amount) public {
        require(block.chainid == 143, "this script only runs on Monad mainnet (chain 143)");
        address who = vm.addr(key);

        require(city.asset() == AUSD, "CITY does not hold AUSD");
        require(city.mayor() == who, "this wallet is not the mayor of CITY");
        address adapter = city.adapters()[0];

        console.log("wallet           ", who);
        console.log("city             ", address(city));
        console.log("phase            ", phase);
        console.log("AUSD before      ", IERC20(AUSD).balanceOf(who));

        vm.startBroadcast(key);
        if (keccak256(bytes(phase)) == keccak256("in")) {
            _in(city, adapter, who, amount);
        } else if (keccak256(bytes(phase)) == keccak256("out")) {
            _out(city, adapter, who);
        } else {
            revert("PHASE must be in or out");
        }
        vm.stopBroadcast();

        console.log("AUSD after       ", IERC20(AUSD).balanceOf(who));
        console.log("city totalAssets ", city.totalAssets());
        console.log("in the adapter   ", IAdapter(adapter).totalAssets());
    }

    function _in(CityVault city, address adapter, address who, uint256 amount) internal {
        require(amount > 0 && amount <= 200e6, "AMOUNT must be between 1 and 200 AUSD (6 decimals)");
        require(IERC20(AUSD).balanceOf(who) >= amount, "wallet holds less AUSD than AMOUNT");

        IERC20(AUSD).approve(address(city), amount);
        city.deposit(amount, who);
        console.log("deposited        ", amount);

        // Morpho rounds a deposit down by a unit, so aim at what is idle, in steps the per-call limit allows.
        for (uint256 i; i < MAX_STEPS; ++i) {
            uint256 idle = IERC20(AUSD).balanceOf(address(city));
            uint256 step = _min(idle, city.totalAssets() * city.maxShiftBps() / BPS);
            if (step <= 2) break;
            city.rebalance(address(0), adapter, step, keccak256(abi.encode("mainnet-proof-in", i)));
            console.log("rebalanced in    ", step);
        }
    }

    function _out(CityVault city, address adapter, address who) internal {
        for (uint256 i; i < MAX_STEPS; ++i) {
            uint256 held = IAdapter(adapter).totalAssets();
            uint256 step = _min(held, city.totalAssets() * city.maxShiftBps() / BPS);
            if (step <= 2) break;
            city.rebalance(adapter, address(0), step, keccak256(abi.encode("mainnet-proof-out", i)));
            console.log("rebalanced out   ", step);
        }
        uint256 shares = city.balanceOf(who);
        uint256 got = city.redeem(shares, who, who);
        console.log("redeemed shares  ", shares);
        console.log("received AUSD    ", got);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
