// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgentMarketplace, IAgentIdentity} from "../src/AgentMarketplace.sol";
import {ApyFeed} from "../src/ApyFeed.sol";
import {CityFactory} from "../src/CityFactory.sol";
import {CityGuardian} from "../src/CityGuardian.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {MirrorYieldAdapter} from "../src/adapters/MirrorYieldAdapter.sol";

/// @notice Deploys the Nusastakes v3 testnet stack on Monad testnet (chain 10143): guardian, factory, APY feed, yield
/// reserve, the simulated-yield adapter and the agent marketplace, then wires them together (the guardian accepts hires
/// from the marketplace for the analyst and public-relations capabilities). All settings default to testnet values and can
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
    /// @dev ERC-8004 Identity Registry on Monad testnet (the shared testnet deployment).
    address internal constant ERC8004_IDENTITY_TESTNET = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    bytes32 internal constant CAPABILITY_ANALIS = keccak256("nusastakes.city-staff.analis");
    bytes32 internal constant CAPABILITY_HUMAS = keccak256("nusastakes.city-staff.humas");
    bytes32 internal constant SOURCE_ID = keccak256("morpho-grove-steakhouse-high-yield-ausd-mainnet");
    string internal constant SOURCE_LABEL = "Morpho Grove x Steakhouse High Yield AUSD (mainnet)";

    struct Deployment {
        address deployer;
        CityGuardian guardian;
        CityFactory factory;
        ApyFeed feed;
        YieldReserve reserve;
        MirrorYieldAdapter mirrorImpl;
        AgentMarketplace market;
    }

    /// @dev Everything read from the environment, grouped so the deploy function does not run out of stack slots.
    struct Settings {
        address asset;
        address treasury;
        address forwarder;
        uint64 chainSelector;
        address updater;
        uint256 depositCap;
        uint256 yieldQuotaPerCity;
        address identityRegistry;
        uint16 marketFeeBps;
    }

    function run() external returns (Deployment memory) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        return deploy(
            deployerKey,
            Settings({
                asset: vm.envOr("ASSET_ADDRESS", AUSD_TESTNET),
                treasury: vm.envOr("PLATFORM_TREASURY", deployer),
                forwarder: vm.envOr("CRE_FORWARDER", CRE_FORWARDER_TESTNET),
                chainSelector: uint64(vm.envOr("CRE_CHAIN_SELECTOR", uint256(MONAD_TESTNET_SELECTOR))),
                updater: vm.envOr("APY_UPDATER", deployer),
                depositCap: vm.envOr("DEPOSIT_CAP", uint256(1_000_000e6)),
                yieldQuotaPerCity: vm.envOr("YIELD_QUOTA_PER_CITY", uint256(1_000e6)),
                identityRegistry: vm.envOr("ERC8004_IDENTITY", ERC8004_IDENTITY_TESTNET),
                marketFeeBps: uint16(vm.envOr("MARKET_FEE_BPS", uint256(500)))
            })
        );
    }

    /// @dev Public so tests can call it with explicit settings instead of process-wide environment variables.
    function deploy(uint256 deployerKey, Settings memory c) public returns (Deployment memory d) {
        address deployer = vm.addr(deployerKey);
        require(c.asset.code.length > 0, "ASSET_ADDRESS has no code on this chain");
        require(c.forwarder != address(0), "CRE_FORWARDER is zero");
        require(c.identityRegistry.code.length > 0, "ERC8004_IDENTITY has no code on this chain");

        vm.startBroadcast(deployerKey);
        d = _deploy(deployer, c);
        vm.stopBroadcast();

        console.log("chainid         ", block.chainid);
        console.log("deployer        ", deployer);
        console.log("asset           ", c.asset);
        console.log("treasury        ", c.treasury);
        console.log("CityGuardian    ", address(d.guardian));
        console.log("CityFactory     ", address(d.factory));
        console.log("ApyFeed         ", address(d.feed));
        console.log("YieldReserve    ", address(d.reserve));
        console.log("MirrorYield impl", address(d.mirrorImpl));
        console.log("AgentMarketplace", address(d.market));
        console.log("identity registry", c.identityRegistry);
        console.log("sourceId        ", vm.toString(SOURCE_ID));
    }

    function _deploy(address deployer, Settings memory c) internal returns (Deployment memory d) {
        d.deployer = deployer;
        d.guardian = new CityGuardian(deployer, c.forwarder, c.chainSelector);
        d.factory = new CityFactory(deployer, IERC20(c.asset), c.treasury, address(d.guardian), c.depositCap);
        d.feed = new ApyFeed(deployer, c.updater, c.forwarder, c.chainSelector);
        d.reserve = new YieldReserve(deployer, IERC20(c.asset), ICityFactory(address(d.factory)), c.yieldQuotaPerCity);
        d.mirrorImpl = new MirrorYieldAdapter();
        d.market = new AgentMarketplace(deployer, IAgentIdentity(c.identityRegistry), c.treasury, c.marketFeeBps);

        d.feed.setSourceLabel(SOURCE_ID, SOURCE_LABEL);
        d.factory.setAllowedAdapter(address(d.mirrorImpl), true);
        d.factory.setAdapterParams(address(d.mirrorImpl), abi.encode(SOURCE_ID, address(d.feed), address(d.reserve)));

        d.market.setAssetAllowed(c.asset, true);
        d.guardian.setMarketplace(address(d.market));
        d.guardian.setCapabilityRole(CAPABILITY_ANALIS, CityGuardian.Role.ANALIS);
        d.guardian.setCapabilityRole(CAPABILITY_HUMAS, CityGuardian.Role.HUMAS);
    }
}
