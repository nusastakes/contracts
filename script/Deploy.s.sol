// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ApyFeed} from "../src/ApyFeed.sol";
import {CityFactory} from "../src/CityFactory.sol";
import {CityGuardian} from "../src/CityGuardian.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {MirrorYieldAdapter} from "../src/adapters/MirrorYieldAdapter.sol";

/// @notice Deploys the Nusastakes testnet stack on Monad testnet (chain 10143): guardian, factory, APY feed, yield
/// reserve and the simulated-yield adapter, then wires them together. All settings default to testnet values and can
/// be overridden with environment variables. The only secret is DEPLOYER_PRIVATE_KEY, read from the environment
/// (never from a file in the repository).
///
///   forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC                      # dry run, sends nothing
///   forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast           # real deploy
///
/// Afterwards the reserve still has to be funded with AUSD (the testnet faucet), see contracts/README.md.
contract Deploy is Script {
    // Monad testnet defaults.
    address internal constant AUSD_TESTNET = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;
    /// @dev Chainlink KeystoneForwarder (production) on Monad testnet. Reports are still refused until a workflow
    /// identity is pinned on the receivers (CreConsumer.identityEnforced).
    address internal constant CRE_FORWARDER_TESTNET = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    uint64 internal constant MONAD_TESTNET_SELECTOR = 2183018362218727504;
    bytes32 internal constant SOURCE_ID = keccak256("morpho-grove-steakhouse-high-yield-ausd-mainnet");
    string internal constant SOURCE_LABEL = "Morpho Grove x Steakhouse High Yield AUSD (mainnet)";

    struct Deployment {
        address deployer;
        CityGuardian guardian;
        CityFactory factory;
        ApyFeed feed;
        YieldReserve reserve;
        MirrorYieldAdapter mirrorImpl;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address asset = vm.envOr("ASSET_ADDRESS", AUSD_TESTNET);
        address treasury = vm.envOr("PLATFORM_TREASURY", deployer);
        address forwarder = vm.envOr("CRE_FORWARDER", CRE_FORWARDER_TESTNET);
        uint64 chainSelector = uint64(vm.envOr("CRE_CHAIN_SELECTOR", uint256(MONAD_TESTNET_SELECTOR)));
        address updater = vm.envOr("APY_UPDATER", deployer);
        uint256 depositCap = vm.envOr("DEPOSIT_CAP", uint256(1_000_000e6));
        uint256 yieldQuotaPerCity = vm.envOr("YIELD_QUOTA_PER_CITY", uint256(1_000e6));

        require(asset.code.length > 0, "ASSET_ADDRESS has no code on this chain");
        require(forwarder != address(0), "CRE_FORWARDER is zero");

        vm.startBroadcast(deployerKey);

        d.deployer = deployer;
        d.guardian = new CityGuardian(deployer, forwarder, chainSelector);
        d.factory = new CityFactory(deployer, IERC20(asset), treasury, address(d.guardian), depositCap);
        d.feed = new ApyFeed(deployer, updater, forwarder, chainSelector);
        d.reserve = new YieldReserve(deployer, IERC20(asset), ICityFactory(address(d.factory)), yieldQuotaPerCity);
        d.mirrorImpl = new MirrorYieldAdapter();

        d.feed.setSourceLabel(SOURCE_ID, SOURCE_LABEL);
        d.factory.setAllowedAdapter(address(d.mirrorImpl), true);
        d.factory.setAdapterParams(address(d.mirrorImpl), abi.encode(SOURCE_ID, address(d.feed), address(d.reserve)));

        vm.stopBroadcast();

        console.log("chainid         ", block.chainid);
        console.log("deployer        ", deployer);
        console.log("asset           ", asset);
        console.log("treasury        ", treasury);
        console.log("CityGuardian    ", address(d.guardian));
        console.log("CityFactory     ", address(d.factory));
        console.log("ApyFeed         ", address(d.feed));
        console.log("YieldReserve    ", address(d.reserve));
        console.log("MirrorYield impl", address(d.mirrorImpl));
        console.log("sourceId        ", vm.toString(SOURCE_ID));
    }
}
