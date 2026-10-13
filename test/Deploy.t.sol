// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {CityGuardian} from "../src/CityGuardian.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {CityVault} from "../src/CityVault.sol";
import {MirrorYieldAdapter} from "../src/adapters/MirrorYieldAdapter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

/// @notice Runs the real deploy script against a mock asset and checks the wiring it produces.
contract DeployScriptTest is Test {
    uint256 internal constant DEPLOYER_KEY = uint256(keccak256("deploy-script-test-deployer"));
    bytes32 internal constant SOURCE_ID = keccak256("morpho-grove-steakhouse-high-yield-ausd-mainnet");

    MockERC20Permit internal asset;
    MockIdentityRegistry internal registry;
    address internal deployer;
    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");
    address internal updater = makeAddr("updater");
    Deploy.Deployment internal d;

    function _settings() internal view returns (Deploy.Settings memory) {
        return Deploy.Settings({
            asset: address(asset),
            treasury: treasury,
            forwarder: forwarder,
            chainSelector: 2183018362218727504,
            updater: updater,
            depositCap: 5_000 * 1e6,
            yieldQuotaPerCity: 300 * 1e6,
            identityRegistry: address(registry),
            marketFeeBps: 500
        });
    }

    function setUp() public {
        asset = new MockERC20Permit();
        registry = new MockIdentityRegistry();
        deployer = vm.addr(DEPLOYER_KEY);
        d = new Deploy().deploy(DEPLOYER_KEY, _settings());
    }

    function test_EverythingIsOwnedByTheDeployerAndWiredTogether() public view {
        assertEq(d.deployer, deployer);
        assertEq(d.factory.owner(), deployer);
        assertEq(d.guardian.owner(), deployer);
        assertEq(d.feed.owner(), deployer);
        assertEq(d.reserve.owner(), deployer);

        assertEq(d.factory.asset(), address(asset));
        assertEq(d.factory.platformTreasury(), treasury);
        assertEq(d.factory.guardian(), address(d.guardian));
        assertEq(d.factory.depositCap(), 5_000 * 1e6);
        assertEq(address(d.reserve.factory()), address(d.factory));
        assertEq(d.reserve.defaultQuota(), 300 * 1e6);
    }

    function test_ReceiversPointAtTheForwarderAndRefuseReportsUntilIdentityIsPinned() public view {
        assertEq(d.guardian.getForwarderAddress(), forwarder);
        assertEq(d.feed.getForwarderAddress(), forwarder);
        assertEq(d.guardian.expectedChainSelector(), 2183018362218727504);
        assertTrue(d.guardian.identityEnforced());
        assertTrue(d.feed.identityEnforced());
        assertEq(d.guardian.getExpectedAuthor(), address(0));
    }

    function test_MirrorAdapterIsAllowedWithPlatformParameters() public view {
        address impl = address(d.mirrorImpl);
        assertTrue(d.factory.allowedAdapterImpl(impl));
        (bytes32 source, address feed, address reserve) =
            abi.decode(d.factory.adapterParams(impl), (bytes32, address, address));
        assertEq(source, SOURCE_ID);
        assertEq(feed, address(d.feed));
        assertEq(reserve, address(d.reserve));
        assertEq(d.feed.sourceLabel(SOURCE_ID), "Morpho Grove x Steakhouse High Yield AUSD (mainnet)");
        assertEq(d.feed.updater(), updater);
    }

    function test_AMayorCanFoundACityAndEarnSimulatedYield() public {
        // Fund the reserve like the faucet would.
        asset.mint(address(d.reserve), 10_000 * 1e6);

        address mayor = makeAddr("mayor");
        address[] memory impls = new address[](1);
        impls[0] = address(d.mirrorImpl);
        vm.prank(mayor);
        CityVault city = CityVault(d.factory.createCity("Deploy check", "", 1000, impls, ""));
        MirrorYieldAdapter mirror = MirrorYieldAdapter(city.adapters()[0]);
        assertEq(city.guardian(), address(d.guardian));
        assertEq(d.reserve.quotaOf(address(mirror)), 300 * 1e6);
        assertTrue(mirror.isSimulated());

        address resident = makeAddr("resident");
        asset.mint(resident, 1_000 * 1e6);
        vm.startPrank(resident);
        asset.approve(address(city), type(uint256).max);
        city.deposit(1_000 * 1e6, resident);
        vm.stopPrank();
        vm.prank(mayor);
        city.rebalance(address(0), address(mirror), 500 * 1e6, bytes32(0));

        vm.prank(updater);
        d.feed.setApy(SOURCE_ID, 1000, uint64(block.timestamp));
        vm.warp(block.timestamp + 365 days);
        assertEq(mirror.totalAssets(), 550 * 1e6);
    }

    function test_TheMarketplaceIsWiredToTheGuardianAndTheAssetAndOwnedByTheDeployer() public view {
        assertEq(d.market.owner(), deployer);
        assertEq(address(d.market.identity()), address(registry));
        assertEq(d.market.treasury(), treasury);
        assertEq(d.market.feeBps(), 500);
        assertTrue(d.market.allowedAsset(address(asset)));
        assertEq(d.guardian.marketplace(), address(d.market));
        assertEq(uint8(d.guardian.capabilityRole(keccak256("nusastakes.city-staff.analis"))), uint8(CityGuardian.Role.ANALIS));
        assertEq(uint8(d.guardian.capabilityRole(keccak256("nusastakes.city-staff.humas"))), uint8(CityGuardian.Role.HUMAS));
    }

    function test_RefusesAnIdentityRegistryThatDoesNotExistOnThisChain() public {
        Deploy.Settings memory c = _settings();
        c.identityRegistry = address(0xdead);
        Deploy script = new Deploy();
        vm.expectRevert("ERC8004_IDENTITY has no code on this chain");
        script.deploy(DEPLOYER_KEY, c);
    }

    function test_RefusesAnAssetThatDoesNotExistOnThisChain() public {
        Deploy.Settings memory c = _settings();
        c.asset = address(0xdead);
        Deploy script = new Deploy();
        vm.expectRevert("ASSET_ADDRESS has no code on this chain");
        script.deploy(DEPLOYER_KEY, c);
    }

    function test_RunReadsTheEnvironmentAndDeploysTheSameStack() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_KEY)));
        vm.setEnv("ASSET_ADDRESS", vm.toString(address(asset)));
        vm.setEnv("PLATFORM_TREASURY", vm.toString(treasury));
        vm.setEnv("CRE_FORWARDER", vm.toString(forwarder));
        vm.setEnv("APY_UPDATER", vm.toString(updater));
        vm.setEnv("DEPOSIT_CAP", "5000000000");
        vm.setEnv("YIELD_QUOTA_PER_CITY", "300000000");
        vm.setEnv("ERC8004_IDENTITY", vm.toString(address(registry)));
        Deploy.Deployment memory viaEnv = new Deploy().run();
        assertEq(viaEnv.factory.depositCap(), 5_000 * 1e6);
        assertEq(viaEnv.guardian.marketplace(), address(viaEnv.market));
        assertEq(viaEnv.market.feeBps(), 500);
    }
}
