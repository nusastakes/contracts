// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CreConsumer} from "./CreConsumer.sol";
import {ICityVault} from "./interfaces/ICityVault.sol";

/// @title CityGuardian
/// @notice One contract for every city. Holds the per-city permissions of AI staff and turns their work into the only
/// two things a vault lets the guardian do: pull an adapter's funds back to idle (`evacuate`), and run a rebalance the
/// mayor approved (`executeProposal`). Agents can never withdraw, set fees, or send funds anywhere.
/// @dev The "satpam" can act through Chainlink CRE: reports arrive via the forwarder and are only honoured for a city
/// whose mayor granted the marker address `CRE_SATPAM` the SATPAM role.
contract CityGuardian is CreConsumer {
    enum Role {
        NONE,
        SATPAM,
        ANALIS,
        HUMAS
    }

    enum Action {
        NONE,
        EVACUATE
    }

    struct Agent {
        Role role;
        uint64 expiry;
    }

    struct Proposal {
        address city;
        address from;
        address to;
        uint256 amount;
        bytes32 planHash;
        address proposer;
        uint64 createdAt;
        bool approved;
    }

    /// @notice Stand-in address a mayor grants the SATPAM role to in order to accept evacuation reports from CRE.
    address public constant CRE_SATPAM = address(uint160(uint256(keccak256("city-vault.cre-satpam"))));
    /// @notice A proposal that the mayor has not approved within this time can no longer be executed.
    uint64 public constant PROPOSAL_TTL = 1 days;
    /// @notice How far ahead of the chain clock a report's `scheduledAt` may be. Keeps one bad report from setting
    /// the replay counter so high that every later report is rejected.
    uint256 public constant SCHEDULED_AT_TOLERANCE = 1 hours;

    /// @notice The staff exchange (`AgentMarketplace`) that may grant hired agents on behalf of a mayor who paid for them.
    address public marketplace;
    /// @notice Which role a marketplace capability grants. SATPAM can never be hired this way: it belongs to the CRE workflow.
    mapping(bytes32 capability => Role) public capabilityRole;

    mapping(address city => mapping(address agent => Agent)) public agents;
    mapping(bytes32 cityAdapterKey => uint256 scheduledAt) public lastScheduledAt;
    Proposal[] private _proposals;

    event AgentGranted(address indexed city, address indexed agent, Role role, uint64 expiry);
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
    event MarketplaceSet(address indexed marketplace);
    event CapabilitySet(bytes32 indexed capability, Role role);
    event EvacuationRequested(
        address indexed city, address indexed adapter, address indexed requester, bytes32 planHash
    );

    error NotMayor(address city, address caller);
    error InvalidAgent();
    error ExpiryInPast(uint64 expiry);
    error NotActiveAgent(address city, address caller, Role required);
    error UnknownProposal(uint256 id);
    error ProposalCityMismatch(uint256 id, address city);
    error ProposalAlreadyApproved(uint256 id);
    error ProposalExpired(uint256 id);
    error UnsupportedAction(uint8 action);
    error StaleReport(uint256 received, uint256 lastAccepted);
    error ScheduledInFuture(uint256 scheduledAt);
    error NotMarketplace(address caller);
    error CapabilityNotHireable(bytes32 capability);
    error RoleNotHireable(Role role);

    /// @dev The deployer becomes the owner (the CRE receiver base does that); ownership moves to `owner_` right away.
    constructor(address owner_, address forwarder_, uint64 chainSelector_) CreConsumer(forwarder_, chainSelector_) {
        if (owner_ != msg.sender) transferOwnership(owner_);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Permissions (mayor only)
    // ---------------------------------------------------------------------------------------------------------

    modifier onlyMayorOf(address city) {
        if (ICityVault(city).mayor() != msg.sender) revert NotMayor(city, msg.sender);
        _;
    }

    function grantAgent(address city, address agent, Role role, uint64 expiry) external onlyMayorOf(city) {
        if (agent == address(0) || role == Role.NONE) revert InvalidAgent();
        if (expiry <= block.timestamp) revert ExpiryInPast(expiry);
        agents[city][agent] = Agent(role, expiry);
        emit AgentGranted(city, agent, role, expiry);
    }

    /// @notice Platform owner: sets the exchange contract that may call `onHire`.
    function setMarketplace(address newMarketplace) external onlyOwner {
        marketplace = newMarketplace;
        emit MarketplaceSet(newMarketplace);
    }

    /// @notice Platform owner: maps a marketplace capability to the role it grants (`Role.NONE` switches it off).
    function setCapabilityRole(bytes32 capability, Role role) external onlyOwner {
        if (role == Role.SATPAM) revert RoleNotHireable(role);
        capabilityRole[capability] = role;
        emit CapabilitySet(capability, role);
    }

    /// @notice Called by the exchange right after `client` paid for an agent. `client` must be the mayor of the city named in
    /// `data` (an ABI-encoded address). The hire adds time: a renewal while the agent is still active extends the
    /// current expiry by the paid duration instead of replacing it.
    function onHire(address client, address agent, bytes32 capability, uint64 expiry, bytes calldata data) external {
        if (msg.sender != marketplace || msg.sender == address(0)) revert NotMarketplace(msg.sender);
        address city = abi.decode(data, (address));
        if (ICityVault(city).mayor() != client) revert NotMayor(city, client);
        Role role = capabilityRole[capability];
        if (role == Role.NONE) revert CapabilityNotHireable(capability);
        if (agent == address(0)) revert InvalidAgent();
        if (expiry <= block.timestamp) revert ExpiryInPast(expiry);
        Agent memory current = agents[city][agent];
        uint64 start = current.role == role && current.expiry > block.timestamp ? current.expiry : uint64(block.timestamp);
        uint64 newExpiry = start + (expiry - uint64(block.timestamp));
        agents[city][agent] = Agent(role, newExpiry);
        emit AgentGranted(city, agent, role, newExpiry);
    }

    function revokeAgent(address city, address agent) external onlyMayorOf(city) {
        delete agents[city][agent];
        emit AgentRevoked(city, agent);
    }

    function isActiveAgent(address city, address agent, Role role) public view returns (bool) {
        Agent memory a = agents[city][agent];
        return a.role == role && role != Role.NONE && block.timestamp < a.expiry;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Analyst proposals
    // ---------------------------------------------------------------------------------------------------------

    /// @notice An active ANALIS agent proposes a rebalance. Nothing moves until the mayor approves it.
    function propose(address city, address from, address to, uint256 amount, bytes32 planHash)
        external
        returns (uint256 id)
    {
        if (!isActiveAgent(city, msg.sender, Role.ANALIS)) {
            revert NotActiveAgent(city, msg.sender, Role.ANALIS);
        }
        id = _proposals.length;
        _proposals.push(Proposal(city, from, to, amount, planHash, msg.sender, uint64(block.timestamp), false));
        emit ProposalCreated(id, city, msg.sender, from, to, amount, planHash);
    }

    /// @notice The mayor approves a proposal, which the vault then executes within its normal limits.
    function approve(address city, uint256 id) external onlyMayorOf(city) {
        if (id >= _proposals.length) revert UnknownProposal(id);
        Proposal storage p = _proposals[id];
        if (p.city != city) revert ProposalCityMismatch(id, city);
        if (p.approved) revert ProposalAlreadyApproved(id);
        if (block.timestamp > uint256(p.createdAt) + PROPOSAL_TTL) revert ProposalExpired(id);
        p.approved = true;
        emit ProposalApproved(id, city, p.planHash);
        ICityVault(city).executeProposal(p.from, p.to, p.amount, p.planHash);
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function proposals(uint256 id) external view returns (Proposal memory) {
        if (id >= _proposals.length) revert UnknownProposal(id);
        return _proposals[id];
    }

    // ---------------------------------------------------------------------------------------------------------
    // Evacuation
    // ---------------------------------------------------------------------------------------------------------

    /// @notice An active SATPAM agent (an EOA or a bot, not CRE) pulls an adapter's funds back to idle.
    function evacuate(address city, address adapter, bytes32 planHash) external {
        if (!isActiveAgent(city, msg.sender, Role.SATPAM)) revert NotActiveAgent(city, msg.sender, Role.SATPAM);
        _evacuate(city, adapter, msg.sender, planHash);
    }

    function _evacuate(address city, address adapter, address requester, bytes32 planHash) internal {
        emit EvacuationRequested(city, adapter, requester, planHash);
        ICityVault(city).evacuate(adapter);
    }

    /// @dev CRE report payload: abi.encode(address target, address city, uint8 action, address adapter,
    /// bytes32 planHash, uint64 chainSelector, uint256 scheduledAt). `scheduledAt` (seconds) must grow for each (city,
    /// adapter) pair and may not be more than an hour ahead of the chain clock, which rejects replays, out-of-order
    /// reports and a timestamp in milliseconds. Only EVACUATE exists, and only for a city whose mayor
    /// granted `CRE_SATPAM` the SATPAM role.
    function _processReport(bytes calldata report) internal override {
        (
            address target,
            address city,
            uint8 action,
            address adapter,
            bytes32 planHash,
            uint64 chainSelector,
            uint256 scheduledAt
        ) = abi.decode(report, (address, address, uint8, address, bytes32, uint64, uint256));

        _checkReport(target, chainSelector);
        if (action != uint8(Action.EVACUATE)) revert UnsupportedAction(action);

        if (scheduledAt > block.timestamp + SCHEDULED_AT_TOLERANCE) revert ScheduledInFuture(scheduledAt);
        bytes32 key = keccak256(abi.encode(city, adapter));
        if (scheduledAt <= lastScheduledAt[key]) revert StaleReport(scheduledAt, lastScheduledAt[key]);
        lastScheduledAt[key] = scheduledAt;

        if (!isActiveAgent(city, CRE_SATPAM, Role.SATPAM)) revert NotActiveAgent(city, CRE_SATPAM, Role.SATPAM);
        _evacuate(city, adapter, CRE_SATPAM, planHash);
    }
}
