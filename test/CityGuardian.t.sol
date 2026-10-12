// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ApyFeed} from "../src/ApyFeed.sol";
import {CityGuardian} from "../src/CityGuardian.sol";
import {CityVault} from "../src/CityVault.sol";
import {CreConsumer} from "../src/CreConsumer.sol";
import {ReceiverTemplate} from "../src/vendor/chainlink/ReceiverTemplate.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

abstract contract CreBase is BaseTest {
    uint64 internal constant CHAIN = 2183018362218727504; // chain-selectors: monad-testnet
    bytes32 internal constant WORKFLOW_ID = keccak256("city-guardian-workflow");

    address internal forwarder = makeAddr("creForwarder");
    address internal creOwner = makeAddr("creWorkflowOwner");

    function _metadata(bytes32 workflowId, address workflowOwner) internal pure returns (bytes memory) {
        // Forwarder layout: workflowId (32) | workflowName (10) | workflowOwner (20) | reportId (2) = 64 bytes.
        return abi.encodePacked(workflowId, bytes10("cityguard"), workflowOwner, bytes2(0x0001));
    }
}

contract CityGuardianTest is CreBase {
    event AgentGranted(address indexed city, address indexed agent, CityGuardian.Role role, uint64 expiry);
    event AgentRevoked(address indexed city, address indexed agent);
    event ProposalCreated(
        uint256 indexed id,
        address indexed city,
        address indexed proposer,
        address from,
        address to,
        uint256 amount,
        bytes32 planHash
    );
    event ProposalApproved(uint256 indexed id, address indexed city, bytes32 planHash);
    event Rebalanced(
        address indexed caller, address indexed from, address indexed to, uint256 amount, bytes32 planHash
    );
    event EvacuationRequested(
        address indexed city, address indexed adapter, address indexed requester, bytes32 planHash
    );

    CityGuardian internal guardian;
    address internal analyst = makeAddr("analyst");
    address internal satpam = makeAddr("satpam");
    bytes32 internal constant PLAN = keccak256("analyst-plan");

    function setUp() public override {
        super.setUp();
        guardian = new CityGuardian(owner, forwarder, CHAIN);
        vm.prank(owner);
        factory.setGuardian(address(guardian));

        // A city founded after the guardian was set, so its vault points at the real guardian.
        vault = _createCity(mayor, 1000);
        address[] memory list = vault.adapters();
        adapterA = MockYieldAdapter(list[0]);
        adapterB = MockYieldAdapter(list[1]);
        _deposit(alice, 1000 * UNIT);
    }

    function _grant(address agent, CityGuardian.Role role) internal {
        vm.prank(mayor);
        guardian.grantAgent(address(vault), agent, role, uint64(block.timestamp + 7 days));
    }

    // ------------------------------------------------------------------ permissions

    function test_OnlyMayorCanGrantAndRevoke() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.NotMayor.selector, address(vault), bob));
        guardian.grantAgent(address(vault), analyst, CityGuardian.Role.ANALIS, expiry);

        vm.expectEmit(true, true, false, true);
        emit AgentGranted(address(vault), analyst, CityGuardian.Role.ANALIS, expiry);
        vm.prank(mayor);
        guardian.grantAgent(address(vault), analyst, CityGuardian.Role.ANALIS, expiry);
        assertTrue(guardian.isActiveAgent(address(vault), analyst, CityGuardian.Role.ANALIS));
        assertFalse(guardian.isActiveAgent(address(vault), analyst, CityGuardian.Role.SATPAM), "role is specific");

        vm.prank(analyst);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.NotMayor.selector, address(vault), analyst));
        guardian.revokeAgent(address(vault), analyst);

        vm.expectEmit(true, true, false, false);
        emit AgentRevoked(address(vault), analyst);
        vm.prank(mayor);
        guardian.revokeAgent(address(vault), analyst);
        assertFalse(guardian.isActiveAgent(address(vault), analyst, CityGuardian.Role.ANALIS));
    }

    function test_GrantValidation() public {
        vm.startPrank(mayor);
        vm.expectRevert(CityGuardian.InvalidAgent.selector);
        guardian.grantAgent(address(vault), address(0), CityGuardian.Role.SATPAM, uint64(block.timestamp + 1));
        vm.expectRevert(CityGuardian.InvalidAgent.selector);
        guardian.grantAgent(address(vault), satpam, CityGuardian.Role.NONE, uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.ExpiryInPast.selector, uint64(block.timestamp)));
        guardian.grantAgent(address(vault), satpam, CityGuardian.Role.SATPAM, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_AgentPermissionExpires() public {
        _grant(analyst, CityGuardian.Role.ANALIS);
        vm.warp(block.timestamp + 7 days);
        assertFalse(guardian.isActiveAgent(address(vault), analyst, CityGuardian.Role.ANALIS));
        vm.prank(analyst);
        vm.expectRevert(
            abi.encodeWithSelector(
                CityGuardian.NotActiveAgent.selector, address(vault), analyst, CityGuardian.Role.ANALIS
            )
        );
        guardian.propose(address(vault), address(0), address(adapterA), 1, PLAN);
    }

    function test_PermissionsAreFencedPerCity() public {
        CityVault other = _createCity(bob, 500);
        address otherAdapter = other.adapters()[0];
        _grant(analyst, CityGuardian.Role.ANALIS);
        vm.prank(analyst);
        vm.expectRevert(
            abi.encodeWithSelector(
                CityGuardian.NotActiveAgent.selector, address(other), analyst, CityGuardian.Role.ANALIS
            )
        );
        guardian.propose(address(other), address(0), otherAdapter, 1, PLAN);
    }

    // ------------------------------------------------------------------ 7. analyst flow

    function test_AnalystProposesMayorApprovesVaultExecutes() public {
        _grant(analyst, CityGuardian.Role.ANALIS);

        vm.expectEmit(true, true, true, true);
        emit ProposalCreated(0, address(vault), analyst, address(0), address(adapterA), 300 * UNIT, PLAN);
        vm.prank(analyst);
        uint256 id = guardian.propose(address(vault), address(0), address(adapterA), 300 * UNIT, PLAN);
        assertEq(id, 0);
        assertEq(adapterA.totalAssets(), 0, "proposing moves nothing");

        vm.expectEmit(true, true, false, true);
        emit ProposalApproved(0, address(vault), PLAN);
        vm.expectEmit(true, true, true, true);
        emit Rebalanced(address(guardian), address(0), address(adapterA), 300 * UNIT, PLAN);
        vm.prank(mayor);
        guardian.approve(address(vault), id);

        assertEq(adapterA.totalAssets(), 300 * UNIT);
        assertTrue(guardian.proposals(0).approved);
        assertEq(guardian.proposalCount(), 1);
    }

    function test_ApproveByAnyoneButTheMayorFails() public {
        _grant(analyst, CityGuardian.Role.ANALIS);
        vm.prank(analyst);
        uint256 id = guardian.propose(address(vault), address(0), address(adapterA), 300 * UNIT, PLAN);

        address[3] memory callers = [analyst, bob, sessionKey];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(CityGuardian.NotMayor.selector, address(vault), callers[i]));
            guardian.approve(address(vault), id);
        }
        assertEq(adapterA.totalAssets(), 0);
    }

    function test_OnlyAnActiveAnalystCanPropose() public {
        _grant(satpam, CityGuardian.Role.SATPAM);
        address[3] memory callers = [bob, mayor, satpam];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CityGuardian.NotActiveAgent.selector, address(vault), callers[i], CityGuardian.Role.ANALIS
                )
            );
            guardian.propose(address(vault), address(0), address(adapterA), 1, PLAN);
        }
    }

    function test_ProposalCannotBeApprovedTwiceOrAfterTtlOrForAnotherCity() public {
        _grant(analyst, CityGuardian.Role.ANALIS);
        vm.prank(analyst);
        uint256 id = guardian.propose(address(vault), address(0), address(adapterA), 100 * UNIT, PLAN);

        vm.prank(mayor);
        guardian.approve(address(vault), id);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.ProposalAlreadyApproved.selector, id));
        guardian.approve(address(vault), id);

        vm.prank(analyst);
        uint256 stale = guardian.propose(address(vault), address(0), address(adapterB), 100 * UNIT, PLAN);
        vm.warp(block.timestamp + 1 days + 1);
        _grant(analyst, CityGuardian.Role.ANALIS); // keep analyst valid; only the proposal is stale
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.ProposalExpired.selector, stale));
        guardian.approve(address(vault), stale);

        CityVault other = _createCity(bob, 500);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.ProposalCityMismatch.selector, stale, address(other)));
        guardian.approve(address(other), stale);

        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.UnknownProposal.selector, 99));
        guardian.approve(address(vault), 99);
    }

    function test_ApprovedProposalStillObeysTheVaultLimits() public {
        _grant(analyst, CityGuardian.Role.ANALIS);
        vm.prank(analyst);
        uint256 id = guardian.propose(address(vault), address(0), address(adapterA), 900 * UNIT, PLAN); // > 50%

        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.ShiftTooHigh.selector, 900 * UNIT, 500 * UNIT));
        guardian.approve(address(vault), id);
        assertFalse(guardian.proposals(id).approved, "failed approval leaves the proposal open");
        assertEq(adapterA.totalAssets(), 0);
    }

    function test_ProposalToAnAdapterOfAnotherCityFails() public {
        CityVault other = _createCity(bob, 500);
        address foreign = other.adapters()[0];
        _grant(analyst, CityGuardian.Role.ANALIS);
        vm.prank(analyst);
        uint256 id = guardian.propose(address(vault), address(0), foreign, 100 * UNIT, PLAN);
        vm.prank(mayor);
        vm.expectRevert(abi.encodeWithSelector(CityVault.UnknownAdapter.selector, foreign));
        guardian.approve(address(vault), id);
    }

    // ------------------------------------------------------------------ satpam (non-CRE)

    function test_SatpamEvacuatesToIdleOnly() public {
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterA), 400 * UNIT, bytes32(0));
        _grant(satpam, CityGuardian.Role.SATPAM);

        vm.expectEmit(true, true, true, true);
        emit EvacuationRequested(address(vault), address(adapterA), satpam, PLAN);
        vm.prank(satpam);
        guardian.evacuate(address(vault), address(adapterA), PLAN);

        assertEq(adapterA.totalAssets(), 0);
        assertEq(asset.balanceOf(address(vault)), 1000 * UNIT);
        assertEq(asset.balanceOf(satpam), 0);
    }

    function test_OnlyAnActiveSatpamCanEvacuate() public {
        _grant(analyst, CityGuardian.Role.ANALIS);
        address[3] memory callers = [analyst, mayor, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CityGuardian.NotActiveAgent.selector, address(vault), callers[i], CityGuardian.Role.SATPAM
                )
            );
            guardian.evacuate(address(vault), address(adapterA), PLAN);
        }
    }

    // ------------------------------------------------------------------ the guardian is not a mayor

    function test_GuardianCannotRebalanceOrWithdrawOrChangeSettings() public {
        vm.startPrank(address(guardian));
        vm.expectRevert(CityVault.NotAuthorizedToRebalance.selector);
        vault.rebalance(address(0), address(adapterA), 1, bytes32(0));
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setFee(0);
        vm.expectRevert(CityVault.NotMayor.selector);
        vault.setSessionKey(sessionKey, uint64(block.timestamp + 1 days), 10_000);
        vm.stopPrank();
    }

    function test_GuardianOwnerIsThePlatform() public view {
        assertEq(guardian.owner(), owner);
        assertEq(guardian.getForwarderAddress(), forwarder);
    }

    // ------------------------------------------------------------------ CRE reports

    function _report(address city, uint8 action, address adapter, uint64 chain, uint256 scheduledAt)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(address(guardian), city, action, adapter, PLAN, chain, scheduledAt);
    }

    function _pinIdentity() internal {
        vm.prank(owner);
        guardian.setExpectedAuthor(creOwner);
    }

    function _enableCreSatpam() internal {
        _grant(guardian.CRE_SATPAM(), CityGuardian.Role.SATPAM);
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterA), 400 * UNIT, bytes32(0));
    }

    function _deliver(bytes memory report) internal {
        vm.prank(forwarder);
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), report);
    }

    function test_CreEvacuationWorksWhenMayorEnabledCreSatpam() public {
        _pinIdentity();
        _enableCreSatpam();

        vm.expectEmit(true, true, true, true);
        emit EvacuationRequested(address(vault), address(adapterA), guardian.CRE_SATPAM(), PLAN);
        _deliver(_report(address(vault), 1, address(adapterA), CHAIN, 100));

        assertEq(adapterA.totalAssets(), 0);
        assertEq(asset.balanceOf(address(vault)), 1000 * UNIT);
    }

    function test_CreReportRefusedIfMayorDidNotEnableCreSatpam() public {
        _pinIdentity();
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterA), 400 * UNIT, bytes32(0));
        address creMarker = guardian.CRE_SATPAM();
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);
        bytes memory report = _report(address(vault), 1, address(adapterA), CHAIN, 100);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CityGuardian.NotActiveAgent.selector, address(vault), creMarker, CityGuardian.Role.SATPAM
            )
        );
        guardian.onReport(meta, report);
        assertEq(adapterA.totalAssets(), 400 * UNIT);
    }

    function test_CreEnabledForOneCityDoesNotCoverAnother() public {
        _pinIdentity();
        _enableCreSatpam();
        CityVault other = _createCity(bob, 500);
        address creMarker = guardian.CRE_SATPAM();
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);
        bytes memory report = _report(address(other), 1, other.adapters()[0], CHAIN, 100);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CityGuardian.NotActiveAgent.selector, address(other), creMarker, CityGuardian.Role.SATPAM
            )
        );
        guardian.onReport(meta, report);
    }

    function test_OnlyTheForwarderMayDeliverReports() public {
        _pinIdentity();
        _enableCreSatpam();
        bytes memory report = _report(address(vault), 1, address(adapterA), CHAIN, 100);
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);

        address[3] memory callers = [bob, mayor, owner];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, callers[i], forwarder));
            guardian.onReport(meta, report);
        }
    }

    function test_ReportsAreRefusedUntilAWorkflowIdentityIsPinned() public {
        _enableCreSatpam();
        vm.prank(forwarder);
        vm.expectRevert(CreConsumer.IdentityNotConfigured.selector);
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 1, address(adapterA), CHAIN, 100));

        // For simulation the owner can switch the rule off on purpose.
        vm.prank(owner);
        guardian.setIdentityEnforced(false);
        _deliver(_report(address(vault), 1, address(adapterA), CHAIN, 100));
        assertEq(adapterA.totalAssets(), 0);
    }

    function test_WrongWorkflowOwnerOrIdIsRefused() public {
        _enableCreSatpam();
        vm.startPrank(owner);
        guardian.setExpectedAuthor(creOwner);
        guardian.setExpectedWorkflowId(WORKFLOW_ID);
        vm.stopPrank();
        bytes memory report = _report(address(vault), 1, address(adapterA), CHAIN, 100);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidAuthor.selector, bob, creOwner));
        guardian.onReport(_metadata(WORKFLOW_ID, bob), report);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, bytes32(uint256(1)), WORKFLOW_ID)
        );
        guardian.onReport(_metadata(bytes32(uint256(1)), creOwner), report);
    }

    function test_ReplayAndOutOfOrderReportsAreRefusedPerCityAdapterPair() public {
        _pinIdentity();
        _enableCreSatpam();
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterB), 400 * UNIT, bytes32(0));

        _deliver(_report(address(vault), 1, address(adapterA), CHAIN, 100));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.StaleReport.selector, 100, 100));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 1, address(adapterA), CHAIN, 100));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.StaleReport.selector, 99, 100));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 1, address(adapterA), CHAIN, 99));

        // Same timestamp for another adapter of the same city is a different pair and is fine.
        _deliver(_report(address(vault), 1, address(adapterB), CHAIN, 100));
        assertEq(adapterB.totalAssets(), 0);
        // A newer timestamp for the first pair is fine too.
        _deliver(_report(address(vault), 1, address(adapterA), CHAIN, 101));
    }

    function test_ReportMustNameThisContractTheRightChainAndAKnownAction() public {
        _pinIdentity();
        _enableCreSatpam();

        bytes memory wrongTarget =
            abi.encode(address(vault), address(vault), uint8(1), address(adapterA), PLAN, CHAIN, uint256(100));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CreConsumer.WrongTarget.selector, address(vault)));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), wrongTarget);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CreConsumer.WrongChain.selector, uint64(1), CHAIN));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 1, address(adapterA), 1, 100));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.UnsupportedAction.selector, uint8(0)));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 0, address(adapterA), CHAIN, 100));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.UnsupportedAction.selector, uint8(2)));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 2, address(adapterA), CHAIN, 100));
    }

    function test_ScheduledAtBeyondToleranceIsRefusedSoItCannotBrickLaterReports() public {
        _pinIdentity();
        _enableCreSatpam();
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);

        // A timestamp in milliseconds, or the maximum value, would otherwise set the replay counter out of reach.
        uint256 wayTooFar = type(uint256).max;
        bytes memory bad = _report(address(vault), 1, address(adapterA), CHAIN, wayTooFar);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.ScheduledInFuture.selector, wayTooFar));
        guardian.onReport(meta, bad);

        uint256 justTooFar = block.timestamp + guardian.SCHEDULED_AT_TOLERANCE() + 1;
        bytes memory bad2 = _report(address(vault), 1, address(adapterA), CHAIN, justTooFar);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityGuardian.ScheduledInFuture.selector, justTooFar));
        guardian.onReport(meta, bad2);

        // The pair is still usable, including right at the tolerance.
        _deliver(
            _report(address(vault), 1, address(adapterA), CHAIN, block.timestamp + guardian.SCHEDULED_AT_TOLERANCE())
        );
        assertEq(adapterA.totalAssets(), 0);
    }

    function test_CreCannotEvacuateAnAdapterOfAnotherCity() public {
        _pinIdentity();
        _enableCreSatpam();
        CityVault other = _createCity(bob, 500);
        address foreign = other.adapters()[0];
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CityVault.UnknownAdapter.selector, foreign));
        guardian.onReport(_metadata(WORKFLOW_ID, creOwner), _report(address(vault), 1, foreign, CHAIN, 100));
    }

    function test_CreSatpamPermissionExpires() public {
        _pinIdentity();
        _enableCreSatpam();
        vm.warp(block.timestamp + 7 days);
        address creMarker = guardian.CRE_SATPAM();
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);
        bytes memory report = _report(address(vault), 1, address(adapterA), CHAIN, 100);
        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CityGuardian.NotActiveAgent.selector, address(vault), creMarker, CityGuardian.Role.SATPAM
            )
        );
        guardian.onReport(meta, report);
    }

    function test_MetadataOf62And64BytesBothWork() public {
        _pinIdentity();
        _enableCreSatpam();
        bytes memory meta62 = abi.encodePacked(WORKFLOW_ID, bytes10("cityguard"), creOwner);
        assertEq(meta62.length, 62);
        vm.prank(forwarder);
        guardian.onReport(meta62, _report(address(vault), 1, address(adapterA), CHAIN, 100));
        assertEq(_metadata(WORKFLOW_ID, creOwner).length, 64);
    }

    /// @dev Payload produced by the TypeScript workflow (cre/city-guardian/risk.ts encodeEvacuationReport) for fixed
    /// inputs. If either side changes its layout this test fails, instead of a real report being refused onchain.
    function test_PayloadEncodedByTheCreWorkflowMatchesWhatTheGuardianDecodes() public {
        bytes memory fromTypeScript =
            hex"000000000000000000000000083899bee8138e5f951db568926393fdb1f418a200000000000000000000000000000000000000000000000000000000000a000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000a1a1a111111111111111111111111111111111111111111111111111111111111111110000000000000000000000000000000000000000000000001e4ba3a26233c850000000000000000000000000000000000000000000000000000000006acd4f00";
        bytes memory fromSolidity = abi.encode(
            address(0x083899bEE8138E5f951db568926393FDb1F418A2),
            address(0x00000000000000000000000000000000000a0001),
            uint8(1),
            address(0x0000000000000000000000000000000000a1A1A1),
            bytes32(0x1111111111111111111111111111111111111111111111111111111111111111),
            uint64(2183018362218727504),
            uint256(1791840000)
        );
        assertEq(fromTypeScript, fromSolidity);
        assertEq(fromTypeScript.length, 224);
    }

    /// @dev A report built exactly like the workflow builds it (target = this guardian, chain selector, fresh
    /// scheduledAt) is accepted and evacuates the adapter.
    function test_ReportBuiltLikeTheWorkflowEvacuatesTheAdapter() public {
        _pinIdentity();
        _enableCreSatpam();
        bytes memory report = abi.encode(
            address(guardian), address(vault), uint8(1), address(adapterA), keccak256("plan"), CHAIN, block.timestamp
        );
        _deliver(report);
        assertEq(adapterA.totalAssets(), 0);
    }

    function test_SupportsTheReceiverInterface() public view {
        assertTrue(guardian.supportsInterface(0x805f2132)); // IReceiver
        assertTrue(guardian.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(guardian.supportsInterface(0xffffffff));
    }
}

contract ApyFeedCreTest is CreBase {
    bytes32 internal constant SOURCE = keccak256("morpho-grove-steakhouse-ausd-mainnet");
    address internal updater = makeAddr("updater");
    ApyFeed internal feed;

    function setUp() public override {
        super.setUp();
        feed = new ApyFeed(owner, updater, forwarder, CHAIN);
    }

    function _report(bytes32 source, uint32 apy, uint64 observedAt, uint64 chain, address target)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(target, source, apy, observedAt, chain);
    }

    function _pin() internal {
        vm.prank(owner);
        feed.setExpectedAuthor(creOwner);
    }

    function test_ValidatedCreReportWritesTheApy() public {
        _pin();
        vm.prank(forwarder);
        feed.onReport(
            _metadata(WORKFLOW_ID, creOwner), _report(SOURCE, 168, uint64(block.timestamp), CHAIN, address(feed))
        );
        (uint32 apy, uint64 observed,) = feed.latest(SOURCE);
        assertEq(apy, 168);
        assertEq(observed, uint64(block.timestamp));
    }

    function test_CreReportIsRefusedWithoutPinnedIdentityOrFromOthers() public {
        bytes memory report = _report(SOURCE, 168, uint64(block.timestamp), CHAIN, address(feed));
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);

        vm.prank(forwarder);
        vm.expectRevert(CreConsumer.IdentityNotConfigured.selector);
        feed.onReport(meta, report);

        _pin();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, bob, forwarder));
        feed.onReport(meta, report);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidAuthor.selector, bob, creOwner));
        feed.onReport(_metadata(WORKFLOW_ID, bob), report);
    }

    function test_CreReportCannotBeReplayedOrSetInsaneValues() public {
        _pin();
        bytes memory meta = _metadata(WORKFLOW_ID, creOwner);
        uint64 t = uint64(block.timestamp);
        vm.prank(forwarder);
        feed.onReport(meta, _report(SOURCE, 100, t, CHAIN, address(feed)));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ApyFeed.StaleObservation.selector, t, t));
        feed.onReport(meta, _report(SOURCE, 100, t, CHAIN, address(feed)));

        vm.warp(block.timestamp + 10);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ApyFeed.ApyTooHigh.selector, uint32(5001)));
        feed.onReport(meta, _report(SOURCE, 5001, t + 10, CHAIN, address(feed)));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CreConsumer.WrongTarget.selector, address(1)));
        feed.onReport(meta, _report(SOURCE, 100, t + 10, CHAIN, address(1)));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CreConsumer.WrongChain.selector, uint64(5), CHAIN));
        feed.onReport(meta, _report(SOURCE, 100, t + 10, 5, address(feed)));
    }

    function test_FeedOwnerIsThePlatformNotTheDeployer() public view {
        assertEq(feed.owner(), owner);
    }
}
