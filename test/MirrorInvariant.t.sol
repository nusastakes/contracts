// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseTest} from "./Base.t.sol";
import {ApyFeed} from "../src/ApyFeed.sol";
import {CityVault} from "../src/CityVault.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {MirrorYieldAdapter} from "../src/adapters/MirrorYieldAdapter.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";

/// @notice Random actions across two cities whose mirror adapters share one small `YieldReserve`.
contract MirrorHandler is Test {
    MockERC20Permit public asset;
    ApyFeed public feed;
    bytes32 public sourceId;
    address public updater;

    CityVault[2] public cities;
    MirrorYieldAdapter[2] public mirrors;
    address[2] public mayors;
    address[] public actors;

    constructor(
        MockERC20Permit asset_,
        ApyFeed feed_,
        bytes32 sourceId_,
        address updater_,
        CityVault[2] memory cities_,
        MirrorYieldAdapter[2] memory mirrors_,
        address[2] memory mayors_
    ) {
        asset = asset_;
        feed = feed_;
        sourceId = sourceId_;
        updater = updater_;
        cities = cities_;
        mirrors = mirrors_;
        mayors = mayors_;
        actors.push(makeAddr("mActor0"));
        actors.push(makeAddr("mActor1"));
        actors.push(makeAddr("mActor2"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 cityIdx, uint256 actorSeed, uint256 amount) external {
        cityIdx %= 2;
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 100_000 * 1e6);
        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(cities[cityIdx]), amount);
        cities[cityIdx].deposit(amount, actor);
        vm.stopPrank();
    }

    function redeem(uint256 cityIdx, uint256 actorSeed, uint256 fractionBps) external {
        cityIdx %= 2;
        address actor = actors[actorSeed % actors.length];
        uint256 shares = cities[cityIdx].balanceOf(actor);
        if (shares == 0) return;
        shares = shares * bound(fractionBps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(actor);
        cities[cityIdx].redeem(shares, actor, actor);
    }

    function toMirror(uint256 cityIdx, uint256 amount) external {
        cityIdx %= 2;
        uint256 idle = asset.balanceOf(address(cities[cityIdx]));
        if (idle == 0) return;
        amount = bound(amount, 1, idle);
        vm.prank(mayors[cityIdx]);
        try cities[cityIdx].rebalance(address(0), address(mirrors[cityIdx]), amount, bytes32(amount)) {} catch {}
    }

    function fromMirror(uint256 cityIdx, uint256 amount) external {
        cityIdx %= 2;
        uint256 held = mirrors[cityIdx].principal();
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(mayors[cityIdx]);
        try cities[cityIdx].rebalance(address(mirrors[cityIdx]), address(0), amount, bytes32(amount)) {} catch {}
    }

    function setApy(uint256 apyBps) external {
        vm.prank(updater);
        feed.setApy(sourceId, uint32(bound(apyBps, 0, 5000)), uint64(block.timestamp));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 60 days));
    }

    function harvest(uint256 cityIdx) external {
        cities[cityIdx % 2].harvestFee();
    }
}

contract MirrorInvariantTest is BaseTest {
    bytes32 internal constant SOURCE = keccak256("mirror-invariant-source");

    ApyFeed internal feed;
    YieldReserve internal reserve;
    MirrorHandler internal handler;
    CityVault[2] internal cities;
    MirrorYieldAdapter[2] internal mirrors;
    address[2] internal mayors;

    function setUp() public override {
        super.setUp();
        address updater = makeAddr("mUpdater");
        feed = new ApyFeed(owner, updater, makeAddr("mForwarder"), 1);
        // Small reserve, so the budgets (3000 + 2000) are fully used and rivalry between cities is real.
        reserve = new YieldReserve(owner, asset, ICityFactory(address(factory)), 3000 * UNIT);
        asset.mint(address(reserve), 5000 * UNIT);

        MirrorYieldAdapter impl = new MirrorYieldAdapter();
        vm.startPrank(owner);
        factory.setAllowedAdapter(address(impl), true);
        factory.setAdapterParams(address(impl), abi.encode(SOURCE, address(feed), address(reserve)));
        vm.stopPrank();

        mayors[0] = makeAddr("mMayor0");
        mayors[1] = makeAddr("mMayor1");
        address[] memory impls = new address[](1);
        impls[0] = address(impl);
        for (uint256 i; i < 2; ++i) {
            vm.prank(mayors[i]);
            cities[i] = CityVault(factory.createCity("City", "", i == 0 ? 1000 : 2000, impls, ""));
            mirrors[i] = MirrorYieldAdapter(cities[i].adapters()[0]);
        }

        handler = new MirrorHandler(asset, feed, SOURCE, updater, cities, mirrors, mayors);
        targetContract(address(handler));
    }

    function _holders() internal view returns (address[] memory list) {
        uint256 n = handler.actorCount();
        list = new address[](n + 3);
        for (uint256 i; i < n; ++i) {
            list[i] = handler.actors(i);
        }
        list[n] = mayors[0];
        list[n + 1] = mayors[1];
        list[n + 2] = treasury;
    }

    /// @dev The reviewer's F-01: the same reserve balance must never be counted by two cities.
    function invariant_BudgetsNeverExceedReserveBalance() public view {
        assertLe(reserve.totalAllocated(), asset.balanceOf(address(reserve)));
    }

    function invariant_UnpaidYieldAcrossCitiesNeverExceedsReserve() public view {
        uint256 unpaid;
        for (uint256 i; i < 2; ++i) {
            unpaid += mirrors[i].totalAssets() - mirrors[i].principal();
        }
        assertLe(unpaid, asset.balanceOf(address(reserve)), "phantom yield: more claimed than the reserve holds");
    }

    function invariant_ClaimsNeverExceedTotalAssetsInEitherCity() public view {
        address[] memory list = _holders();
        for (uint256 c; c < 2; ++c) {
            uint256 claims;
            for (uint256 i; i < list.length; ++i) {
                claims += cities[c].convertToAssets(cities[c].balanceOf(list[i]));
            }
            assertLe(claims, cities[c].totalAssets(), "claims exceed assets");
        }
    }

    /// @dev Everybody in both cities can exit completely, even after the reserve budgets ran out.
    function invariant_EveryoneCanExitBothCities() public {
        uint256 snap = vm.snapshotState();
        address[] memory list = _holders();
        for (uint256 c; c < 2; ++c) {
            uint256 assetsBefore = cities[c].totalAssets();
            uint256 supplyBefore = cities[c].totalSupply();
            cities[c].harvestFee();
            for (uint256 pass; pass < 3; ++pass) {
                for (uint256 i; i < list.length; ++i) {
                    uint256 shares = cities[c].balanceOf(list[i]);
                    if (shares == 0) continue;
                    vm.prank(list[i]);
                    cities[c].redeem(shares, list[i], list[i]);
                }
            }
            assertEq(cities[c].totalSupply(), 0, "shares left over");
            uint256 virtualShare = (assetsBefore + 1) * 1e6 / (supplyBefore + 1e6);
            assertLe(
                cities[c].totalAssets(), virtualShare + 2 * list.length + 2, "more than virtual-share and dust left"
            );
        }
        vm.revertToState(snap);
    }
}
