// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHireHook} from "./interfaces/IHireHook.sol";

/// @notice The two ERC-8004 Identity Registry functions this contract uses.
interface IAgentIdentity is IERC721 {
    function getAgentWallet(uint256 agentId) external view returns (address);
}

/// @title AgentMarketplace
/// @notice A small, general marketplace for AI agents that are registered in the ERC-8004 Identity Registry. The owner of an
/// agent lists a service with a price per period; a client hires it by paying that price, which goes straight to the agent's
/// wallet (minus a capped platform fee). Nothing is held in escrow: the contract never keeps funds.
///
/// It knows nothing about cities. What a hire *does* is up to an optional hook that the client names, called after payment
/// with the paying account: `CityGuardian.onHire` grants the agent a role in the client's city, but any application can
/// write its own hook (a DAO, a game, a vault). On-chain stats (number of hires, revenue) come from real payments, so they
/// cannot be inflated with free accounts the way ratings can.
/// @dev Trust assumptions: the Identity Registry is the official ERC-8004 deployment; the owner can allow payment tokens,
/// set the treasury and a fee up to 10%, and pause new listings and hires; it cannot touch a hire that already happened.
/// Payment tokens should be plain ERC-20s (no fee on transfer), which is why the owner allow-lists them.
contract AgentMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint32 public constant MIN_PERIOD = 1 hours;
    uint32 public constant MAX_PERIOD = 365 days;
    uint8 public constant MAX_PERIODS_PER_HIRE = 52;
    uint8 public constant MAX_LISTINGS_PER_AGENT = 4;
    uint256 public constant MAX_URI_LENGTH = 512;

    struct Listing {
        uint256 agentId;
        address seller; // who controlled the agent when the listing was made or last updated
        address asset;
        uint128 price; // per period, in `asset` units
        uint32 period; // seconds one paid period lasts
        bytes32 capability; // what the agent does, for example keccak256("nusastakes.city-staff.analis")
        bool active;
        string uri; // optional pointer to a longer description
    }

    struct Stats {
        uint64 hires;
        uint64 lastHireAt;
        uint128 revenue; // total paid to the agent, after the platform fee, in the listing's asset
    }

    IAgentIdentity public immutable identity;
    address public treasury;
    uint16 public feeBps;
    bool public paused;
    mapping(address token => bool) public allowedAsset;

    Listing[] private _listings;
    mapping(uint256 listingId => Stats) private _stats;
    mapping(uint256 agentId => uint256[]) private _listingsOfAgent;
    mapping(uint256 listingId => mapping(address client => uint64)) public hiredUntil;

    event Listed(uint256 indexed listingId, uint256 indexed agentId, address indexed seller, address asset, uint128 price, uint32 period, bytes32 capability);
    event ListingUpdated(uint256 indexed listingId, address indexed seller, uint128 price, uint32 period, bool active);
    event Hired(
        uint256 indexed listingId,
        uint256 indexed agentId,
        address indexed client,
        address agentWallet,
        bytes32 capability,
        uint64 until,
        uint256 paidToAgent,
        uint256 fee
    );
    event TreasurySet(address treasury);
    event FeeSet(uint16 feeBps);
    event AssetAllowed(address indexed token, bool allowed);
    event PausedSet(bool paused);

    error NotAgentController(uint256 agentId, address caller);
    error AgentHasNoWallet(uint256 agentId);
    error AssetNotAllowed(address token);
    error PeriodOutOfRange(uint32 period);
    error PeriodsOutOfRange(uint64 periods);
    error TooManyListings(uint256 agentId);
    error EmptyCapability();
    error UriTooLong();
    error UnknownListing(uint256 listingId);
    error ListingInactive(uint256 listingId);
    error ListingStale(uint256 listingId);
    error PriceChanged(uint256 total, uint256 maxTotal);
    error FeeTooHigh(uint16 feeBps);
    error IsPaused();
    error ZeroAddress();

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    constructor(address owner_, IAgentIdentity identity_, address treasury_, uint16 feeBps_) Ownable(owner_) {
        if (address(identity_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        identity = identity_;
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Listing
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Lists a service of an agent you control (its ERC-721 owner, or an account the owner approved).
    function list(uint256 agentId, bytes32 capability, address asset, uint128 price, uint32 period, string calldata uri)
        external
        whenNotPaused
        returns (uint256 listingId)
    {
        _requireController(agentId, msg.sender);
        if (identity.getAgentWallet(agentId) == address(0)) revert AgentHasNoWallet(agentId);
        if (capability == bytes32(0)) revert EmptyCapability();
        if (!allowedAsset[asset]) revert AssetNotAllowed(asset);
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert PeriodOutOfRange(period);
        if (bytes(uri).length > MAX_URI_LENGTH) revert UriTooLong();
        if (_listingsOfAgent[agentId].length >= MAX_LISTINGS_PER_AGENT) revert TooManyListings(agentId);

        listingId = _listings.length;
        address seller = identity.ownerOf(agentId);
        _listings.push(Listing(agentId, seller, asset, price, period, capability, true, uri));
        _listingsOfAgent[agentId].push(listingId);
        emit Listed(listingId, agentId, seller, asset, price, period, capability);
    }

    /// @notice Changes price, period, whether it is open, and the pointer. Whoever controls the agent *now* may do this, which
    /// is also how a new owner takes over a listing that went stale after the agent was transferred.
    function update(uint256 listingId, uint128 price, uint32 period, bool active, string calldata uri) external whenNotPaused {
        Listing storage l = _listing(listingId);
        _requireController(l.agentId, msg.sender);
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert PeriodOutOfRange(period);
        if (bytes(uri).length > MAX_URI_LENGTH) revert UriTooLong();
        l.price = price;
        l.period = period;
        l.active = active;
        l.uri = uri;
        l.seller = identity.ownerOf(l.agentId);
        emit ListingUpdated(listingId, l.seller, price, period, active);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Hiring
    // ---------------------------------------------------------------------------------------------------------

    /// @notice What `periods` periods of a listing cost: the total, the platform fee, and what the agent receives.
    function quote(uint256 listingId, uint64 periods) public view returns (uint256 total, uint256 fee, uint256 toAgent) {
        Listing storage l = _listing(listingId);
        total = uint256(l.price) * periods;
        fee = (total * feeBps) / BPS;
        toAgent = total - fee;
    }

    /// @notice Pays for `periods` periods of an agent. The agent's wallet gets the price minus the platform fee, directly from
    /// the caller. `maxTotal` is the most the caller agrees to pay in total: the seller can change the price at any time, so
    /// without it a price raised just before this transaction would be paid anyway. If `hook` is set it is called afterwards
    /// with the caller as `client`; if the hook reverts, so does the hire and no payment moves. The caller must have approved
    /// this contract for the total price (or use `hireWithPermit`).
    function hire(uint256 listingId, uint64 periods, uint256 maxTotal, address hook, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        returns (uint64 until)
    {
        return _hire(listingId, periods, maxTotal, hook, data);
    }

    /// @notice Same as `hire`, with an EIP-2612 permit for the payment so the caller needs no separate approval. A permit that
    /// someone else already used is tolerated; the payment then relies on the allowance it left.
    function hireWithPermit(
        uint256 listingId,
        uint64 periods,
        uint256 maxTotal,
        address hook,
        bytes calldata data,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint64 until) {
        (uint256 total,,) = quote(listingId, periods);
        try IERC20Permit(_listing(listingId).asset).permit(msg.sender, address(this), total, deadline, v, r, s) {} catch {}
        return _hire(listingId, periods, maxTotal, hook, data);
    }

    function _hire(uint256 listingId, uint64 periods, uint256 maxTotal, address hook, bytes calldata data)
        internal
        returns (uint64 until)
    {
        Listing storage l = _listing(listingId);
        if (!l.active) revert ListingInactive(listingId);
        if (periods == 0 || periods > MAX_PERIODS_PER_HIRE) revert PeriodsOutOfRange(periods);
        (uint256 total,,) = quote(listingId, periods);
        if (total > maxTotal) revert PriceChanged(total, maxTotal);
        // The listing is only good while the account that listed it still controls the agent, and the agent still has a wallet.
        if (identity.ownerOf(l.agentId) != l.seller) revert ListingStale(listingId);
        address wallet = identity.getAgentWallet(l.agentId);
        if (wallet == address(0)) revert AgentHasNoWallet(l.agentId);

        uint64 duration = uint64(uint256(l.period) * periods);
        until = _extend(listingId, duration);
        _settle(listingId, l, wallet, periods, until);
        if (hook != address(0)) IHireHook(hook).onHire(msg.sender, wallet, l.capability, uint64(block.timestamp + duration), data);
    }

    /// @dev Adds `duration` to the caller's current hire of the listing (or starts a new one now).
    function _extend(uint256 listingId, uint64 duration) internal returns (uint64 until) {
        uint64 previous = hiredUntil[listingId][msg.sender];
        uint64 start = previous > block.timestamp ? previous : uint64(block.timestamp);
        until = start + duration;
        hiredUntil[listingId][msg.sender] = until;
    }

    /// @dev Records the hire and moves the money: price minus fee to the agent's wallet, the fee to the treasury.
    function _settle(uint256 listingId, Listing storage l, address wallet, uint64 periods, uint64 until) internal {
        (uint256 total, uint256 fee, uint256 toAgent) = quote(listingId, periods);
        Stats storage st = _stats[listingId];
        st.hires += 1;
        st.lastHireAt = uint64(block.timestamp);
        st.revenue += uint128(toAgent);
        emit Hired(listingId, l.agentId, msg.sender, wallet, l.capability, until, toAgent, fee);

        if (total > 0) {
            IERC20 token = IERC20(l.asset);
            if (toAgent > 0) token.safeTransferFrom(msg.sender, wallet, toAgent);
            if (fee > 0) token.safeTransferFrom(msg.sender, treasury, fee);
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    function listingCount() external view returns (uint256) {
        return _listings.length;
    }

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listing(listingId);
    }

    function statsOf(uint256 listingId) external view returns (Stats memory) {
        _listing(listingId);
        return _stats[listingId];
    }

    function listingIdsOf(uint256 agentId) external view returns (uint256[] memory) {
        return _listingsOfAgent[agentId];
    }

    /// @notice True while `client` has an unexpired hire of this listing through this contract.
    function isHired(uint256 listingId, address client) external view returns (bool) {
        return hiredUntil[listingId][client] > block.timestamp;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Platform owner
    // ---------------------------------------------------------------------------------------------------------

    function setAssetAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedAsset[token] = allowed;
        emit AssetAllowed(token, allowed);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    function setFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        feeBps = newFeeBps;
        emit FeeSet(newFeeBps);
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------

    function _listing(uint256 listingId) internal view returns (Listing storage) {
        if (listingId >= _listings.length) revert UnknownListing(listingId);
        return _listings[listingId];
    }

    function _requireController(uint256 agentId, address account) internal view {
        address owner_ = identity.ownerOf(agentId); // reverts for an agent that does not exist
        if (account != owner_ && identity.getApproved(agentId) != account && !identity.isApprovedForAll(owner_, account)) {
            revert NotAgentController(agentId, account);
        }
    }
}
