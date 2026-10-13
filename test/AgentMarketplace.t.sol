// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgentMarketplace, IAgentIdentity} from "../src/AgentMarketplace.sol";
import {CityFactory} from "../src/CityFactory.sol";
import {CityGuardian} from "../src/CityGuardian.sol";
import {CityVault} from "../src/CityVault.sol";
import {IHireHook} from "../src/interfaces/IHireHook.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

/// @dev A hook that tries to hire again from inside the hire.
contract ReenteringHook is IHireHook {
    AgentMarketplace public market;

    constructor(AgentMarketplace m) {
        market = m;
    }

    function onHire(address, address, bytes32, uint64, bytes calldata) external {
        market.hire(0, 1, address(0), "");
    }
}

contract AgentMarketplaceTest is Test {
    uint256 internal constant UNIT = 1e6;
    bytes32 internal constant ANALIS = keccak256("nusastakes.city-staff.analis");
    bytes32 internal constant HUMAS = keccak256("nusastakes.city-staff.humas");

    MockIdentityRegistry internal identity;
    MockERC20Permit internal asset;
    AgentMarketplace internal market;
    CityGuardian internal guardian;
    CityFactory internal factory;
    CityVault internal city;

    address internal platform = makeAddr("platform");
    address internal treasury = makeAddr("treasury");
    address internal seller = makeAddr("seller"); // owns the agent identity
    address internal agentWallet = makeAddr("agentWallet"); // the agent's own wallet
    address internal mayor = makeAddr("mayor");
    address internal stranger = makeAddr("stranger");
    uint256 internal buyerPk;
    address internal buyer;
    uint256 internal agentId;
    uint256 internal listingId;

    function setUp() public {
        (buyer, buyerPk) = makeAddrAndKey("buyer");
        identity = new MockIdentityRegistry();
        asset = new MockERC20Permit();
        market = new AgentMarketplace(platform, IAgentIdentity(address(identity)), treasury, 500);
        vm.prank(platform);
        market.setAssetAllowed(address(asset), true);

        vm.prank(seller);
        agentId = identity.register(seller);
        identity.setWallet(agentId, agentWallet);
        vm.prank(seller);
        listingId = market.list(agentId, ANALIS, address(asset), uint128(100 * UNIT), 7 days, "ipfs://card");

        // A real guardian, factory and city so the hook is exercised for real.
        guardian = new CityGuardian(platform, makeAddr("forwarder"), 1);
        factory = new CityFactory(platform, IERC20(address(asset)), treasury, address(guardian), 1_000_000 * UNIT);
        MockYieldAdapter impl = new MockYieldAdapter();
        vm.prank(platform);
        factory.setAllowedAdapter(address(impl), true);
        address[] memory impls = new address[](1);
        impls[0] = address(impl);
        vm.prank(mayor);
        city = CityVault(factory.createCity("Jakarta", "", 1000, impls, ""));
        vm.startPrank(platform);
        guardian.setMarketplace(address(market));
        guardian.setCapabilityRole(ANALIS, CityGuardian.Role.ANALIS);
        guardian.setCapabilityRole(HUMAS, CityGuardian.Role.HUMAS);
        vm.stopPrank();

        asset.mint(buyer, 10_000 * UNIT);
        asset.mint(mayor, 10_000 * UNIT);
        vm.prank(buyer);
        asset.approve(address(market), type(uint256).max);
        vm.prank(mayor);
        asset.approve(address(market), type(uint256).max);
    }

    // ───────────────────────────── listing ─────────────────────────────

    function test_ListingRecordsTheServiceAndCountsAsTheAgentsOwn() public view {
        AgentMarketplace.Listing memory l = market.getListing(listingId);
        assertEq(l.agentId, agentId);
        assertEq(l.seller, seller);
        assertEq(l.price, 100 * UNIT);
        assertEq(l.period, 7 days);
        assertTrue(l.active);
        assertEq(market.listingCount(), 1);
        assertEq(market.listingIdsOf(agentId).length, 1);
    }

    function test_OnlyWhoControlsTheAgentMayListIt() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.NotAgentController.selector, agentId, stranger));
        market.list(agentId, ANALIS, address(asset), 1, 1 days, "");

        vm.prank(seller);
        identity.approve(stranger, agentId); // an approved operator may list for the owner
        vm.prank(stranger);
        market.list(agentId, HUMAS, address(asset), 1, 1 days, "");
        assertEq(market.getListing(1).seller, seller, "the listing belongs to the owner, not the operator");

        vm.prank(stranger);
        vm.expectRevert(); // an agent that does not exist
        market.list(999, ANALIS, address(asset), 1, 1 days, "");
    }

    function test_ListingRulesAreEnforced() public {
        vm.startPrank(seller);
        vm.expectRevert(AgentMarketplace.EmptyCapability.selector);
        market.list(agentId, bytes32(0), address(asset), 1, 1 days, "");
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.AssetNotAllowed.selector, address(0xbeef)));
        market.list(agentId, ANALIS, address(0xbeef), 1, 1 days, "");
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.PeriodOutOfRange.selector, uint32(59 minutes)));
        market.list(agentId, ANALIS, address(asset), 1, 59 minutes, "");
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.PeriodOutOfRange.selector, uint32(366 days)));
        market.list(agentId, ANALIS, address(asset), 1, 366 days, "");
        vm.expectRevert(AgentMarketplace.UriTooLong.selector);
        market.list(agentId, ANALIS, address(asset), 1, 1 days, new string(513));
        // Four listings per agent, the first one exists already.
        for (uint256 i; i < 3; ++i) market.list(agentId, ANALIS, address(asset), 1, 1 days, "");
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.TooManyListings.selector, agentId));
        market.list(agentId, ANALIS, address(asset), 1, 1 days, "");
        vm.stopPrank();

        identity.setWallet(agentId, address(0));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.AgentHasNoWallet.selector, agentId));
        market.list(agentId, ANALIS, address(asset), 1, 1 days, "");
    }

    function test_OnlyTheControllerUpdatesAndAStrangerCannotTouchAListing() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.NotAgentController.selector, agentId, stranger));
        market.update(listingId, 1, 1 days, false, "");

        vm.prank(seller);
        market.update(listingId, uint128(50 * UNIT), 3 days, true, "new");
        AgentMarketplace.Listing memory l = market.getListing(listingId);
        assertEq(l.price, 50 * UNIT);
        assertEq(l.period, 3 days);
        assertEq(l.uri, "new");
    }

    // ───────────────────────────── hiring and payment ─────────────────────────────

    function test_HiringPaysTheAgentsWalletMinusTheFeeAndKeepsNothing() public {
        (uint256 total, uint256 fee, uint256 toAgent) = market.quote(listingId, 3);
        assertEq(total, 300 * UNIT);
        assertEq(fee, 15 * UNIT);
        assertEq(toAgent, 285 * UNIT);

        vm.prank(buyer);
        uint64 until = market.hire(listingId, 3, address(0), "");
        assertEq(until, block.timestamp + 21 days);
        assertEq(asset.balanceOf(agentWallet), 285 * UNIT, "the money goes to the agent's wallet, not the NFT owner");
        assertEq(asset.balanceOf(seller), 0);
        assertEq(asset.balanceOf(treasury), 15 * UNIT);
        assertEq(asset.balanceOf(address(market)), 0, "the marketplace never holds funds");
        assertEq(asset.balanceOf(buyer), 10_000 * UNIT - 300 * UNIT);
        assertTrue(market.isHired(listingId, buyer));
        assertFalse(market.isHired(listingId, stranger));

        AgentMarketplace.Stats memory st = market.statsOf(listingId);
        assertEq(st.hires, 1);
        assertEq(st.revenue, 285 * UNIT);
        assertEq(st.lastHireAt, block.timestamp);
    }

    function test_RenewingAddsTimeInsteadOfReplacingIt() public {
        vm.startPrank(buyer);
        uint64 first = market.hire(listingId, 1, address(0), "");
        vm.warp(block.timestamp + 2 days);
        uint64 second = market.hire(listingId, 2, address(0), "");
        vm.stopPrank();
        assertEq(second, first + 14 days);
        vm.warp(block.timestamp + 30 days);
        assertFalse(market.isHired(listingId, buyer), "the hire runs out");
    }

    function test_HireRulesAreEnforced() public {
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.PeriodsOutOfRange.selector, uint64(0)));
        market.hire(listingId, 0, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.PeriodsOutOfRange.selector, uint64(53)));
        market.hire(listingId, 53, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.UnknownListing.selector, uint256(7)));
        market.hire(7, 1, address(0), "");
        vm.stopPrank();

        vm.prank(seller);
        market.update(listingId, uint128(100 * UNIT), 7 days, false, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.ListingInactive.selector, listingId));
        market.hire(listingId, 1, address(0), "");
    }

    function test_AListingGoesStaleWhenTheAgentChangesHandsAndTheNewOwnerCanClaimIt() public {
        vm.prank(seller);
        identity.transferFrom(seller, stranger, agentId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.ListingStale.selector, listingId));
        market.hire(listingId, 1, address(0), "");

        vm.prank(stranger);
        market.update(listingId, uint128(10 * UNIT), 7 days, true, "");
        assertEq(market.getListing(listingId).seller, stranger);
        vm.prank(buyer);
        market.hire(listingId, 1, address(0), "");
    }

    function test_AnAgentWithoutAWalletCannotBeHired() public {
        identity.setWallet(agentId, address(0));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.AgentHasNoWallet.selector, agentId));
        market.hire(listingId, 1, address(0), "");
    }

    function test_WithoutApprovalTheHireFailsAndNothingMoves() public {
        vm.prank(stranger);
        vm.expectRevert();
        market.hire(listingId, 1, address(0), "");
        assertEq(market.statsOf(listingId).hires, 0);
    }

    function test_FreeListingsNeedNoApprovalAndStillCountAsHires() public {
        vm.prank(seller);
        uint256 free = market.list(agentId, HUMAS, address(asset), 0, 1 days, "");
        vm.prank(stranger);
        market.hire(free, 2, address(0), "");
        assertEq(market.statsOf(free).hires, 1);
        assertEq(market.statsOf(free).revenue, 0);
        assertTrue(market.isHired(free, stranger));
    }

    function test_HireWithPermitNeedsNoSeparateApproval() public {
        vm.prank(buyer);
        asset.approve(address(market), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(buyerPk, buyer, address(market), 100 * UNIT, deadline);
        vm.prank(buyer);
        market.hireWithPermit(listingId, 1, address(0), "", deadline, v, r, s);
        assertEq(asset.balanceOf(agentWallet), 95 * UNIT);
    }

    function test_ASpentPermitDoesNotBlockTheHireWhenTheAllowanceIsThere() public {
        vm.prank(buyer);
        asset.approve(address(market), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(buyerPk, buyer, address(market), 100 * UNIT, deadline);
        asset.permit(buyer, address(market), 100 * UNIT, deadline, v, r, s); // somebody front-ran the permit
        vm.prank(buyer);
        market.hireWithPermit(listingId, 1, address(0), "", deadline, v, r, s);
        assertEq(asset.balanceOf(agentWallet), 95 * UNIT);
    }

    // ───────────────────────────── the city hook ─────────────────────────────

    function test_ARealHireByTheMayorGrantsTheAgentItsRoleInTheCity() public {
        assertFalse(guardian.isActiveAgent(address(city), agentWallet, CityGuardian.Role.ANALIS));
        vm.prank(mayor);
        market.hire(listingId, 2, address(guardian), abi.encode(address(city)));
        assertTrue(guardian.isActiveAgent(address(city), agentWallet, CityGuardian.Role.ANALIS));
        (CityGuardian.Role role, uint64 expiry) = guardian.agents(address(city), agentWallet);
        assertEq(uint8(role), uint8(CityGuardian.Role.ANALIS));
        assertEq(expiry, block.timestamp + 14 days);
        assertEq(asset.balanceOf(agentWallet), 190 * UNIT);

        // The hired agent really can propose.
        address adapter = city.adapters()[0]; // read before the prank, which only covers the next call
        vm.prank(agentWallet);
        guardian.propose(address(city), address(0), adapter, 1, bytes32(0));
    }

    function test_AHireByWhoIsNotTheMayorRevertsAsAWholeAndNoMoneyMoves() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.NotMayor.selector, address(city), buyer));
        market.hire(listingId, 1, address(guardian), abi.encode(address(city)));
        assertEq(asset.balanceOf(agentWallet), 0);
        assertEq(asset.balanceOf(buyer), 10_000 * UNIT);
        assertEq(market.statsOf(listingId).hires, 0);
        assertFalse(guardian.isActiveAgent(address(city), agentWallet, CityGuardian.Role.ANALIS));
    }

    function test_RenewalThroughTheHookExtendsTheCityGrant() public {
        vm.startPrank(mayor);
        market.hire(listingId, 1, address(guardian), abi.encode(address(city)));
        vm.warp(block.timestamp + 3 days);
        market.hire(listingId, 1, address(guardian), abi.encode(address(city)));
        vm.stopPrank();
        (, uint64 expiry) = guardian.agents(address(city), agentWallet);
        assertEq(expiry, block.timestamp - 3 days + 14 days, "7 days from the first hire plus 7 days more");
    }

    function test_OnlyTheMarketplaceMayCallTheHookAndSatpamCanNeverBeHired() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.NotMarketplace.selector, stranger));
        guardian.onHire(mayor, agentWallet, ANALIS, uint64(block.timestamp + 1 days), abi.encode(address(city)));

        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.RoleNotHireable.selector, CityGuardian.Role.SATPAM));
        guardian.setCapabilityRole(keccak256("anything"), CityGuardian.Role.SATPAM);

        vm.prank(seller);
        uint256 odd = market.list(agentId, keccak256("not-mapped"), address(asset), 0, 1 days, "");
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.CapabilityNotHireable.selector, keccak256("not-mapped")));
        market.hire(odd, 1, address(guardian), abi.encode(address(city)));

        vm.prank(stranger);
        vm.expectRevert();
        guardian.setMarketplace(stranger);
    }

    function test_AMaliciousHookCannotReenterTheMarketplace() public {
        ReenteringHook hook = new ReenteringHook(market);
        vm.prank(buyer);
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        market.hire(listingId, 1, address(hook), "");
        assertEq(asset.balanceOf(agentWallet), 0, "the whole hire is undone");
    }

    function test_AGuardianWithoutAMarketplaceRefusesHires() public {
        CityGuardian other = new CityGuardian(platform, makeAddr("forwarder2"), 1);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.NotMarketplace.selector, address(market)));
        market.hire(listingId, 1, address(other), abi.encode(address(city)));
    }

    // ───────────────────────────── platform owner ─────────────────────────────

    function test_OwnerControlsAreLimited() public {
        vm.startPrank(platform);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.FeeTooHigh.selector, uint16(1001)));
        market.setFee(1001);
        market.setFee(1000);
        vm.expectRevert(AgentMarketplace.ZeroAddress.selector);
        market.setTreasury(address(0));
        vm.expectRevert(AgentMarketplace.ZeroAddress.selector);
        market.setAssetAllowed(address(0), true);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert();
        market.setFee(0);
        vm.prank(stranger);
        vm.expectRevert();
        market.setPaused(true);
    }

    function test_PausingStopsNewListingsAndHiresOnly() public {
        vm.prank(platform);
        market.setPaused(true);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.IsPaused.selector);
        market.hire(listingId, 1, address(0), "");
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.IsPaused.selector);
        market.list(agentId, ANALIS, address(asset), 1, 1 days, "");
        assertEq(market.getListing(listingId).price, 100 * UNIT, "views still work");
    }

    function test_ConstructorRejectsABadSetup() public {
        vm.expectRevert(AgentMarketplace.ZeroAddress.selector);
        new AgentMarketplace(platform, IAgentIdentity(address(0)), treasury, 500);
        vm.expectRevert(AgentMarketplace.ZeroAddress.selector);
        new AgentMarketplace(platform, IAgentIdentity(address(identity)), address(0), 500);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.FeeTooHigh.selector, uint16(1001)));
        new AgentMarketplace(platform, IAgentIdentity(address(identity)), treasury, 1001);
    }

    function testFuzz_PaymentsAreConservedExactly(uint96 price, uint8 periods, uint16 feeBps) public {
        price = uint96(bound(price, 0, 1_000_000 * UNIT));
        periods = uint8(bound(periods, 1, 52));
        feeBps = uint16(bound(feeBps, 0, 1000));
        vm.prank(platform);
        market.setFee(feeBps);
        vm.prank(seller);
        uint256 id = market.list(agentId, HUMAS, address(asset), price, 1 days, "");
        uint256 total = uint256(price) * periods;
        asset.mint(buyer, total);
        uint256 before = asset.balanceOf(buyer);
        vm.prank(buyer);
        market.hire(id, periods, address(0), "");
        assertEq(before - asset.balanceOf(buyer), total, "the buyer pays exactly the total");
        assertEq(asset.balanceOf(agentWallet) + asset.balanceOf(treasury), total, "and all of it arrives, split by the fee");
        assertLe(asset.balanceOf(treasury), (total * 1000) / 10_000);
        assertEq(asset.balanceOf(address(market)), 0);
    }

    function _permit(uint256 pk, address tokenOwner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 typeHash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, tokenOwner, spender, value, asset.nonces(tokenOwner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", asset.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }
}
