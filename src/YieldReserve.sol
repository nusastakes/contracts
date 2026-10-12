// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICityFactory} from "./interfaces/ICityFactory.sol";

/// @notice Platform-owned pool of testnet AUSD that pays the simulated yield of `MirrorYieldAdapter` clones.
/// This exists only where no real protocol accepts the asset (Gate A = C); it is always labelled as simulated.
/// @dev Every adapter clone gets its own yield budget (`quotaOf`) carved out of the reserve when it enrolls, and the
/// sum of all budgets never exceeds the balance. That is what keeps cities from double-counting the same reserve
/// balance in their share price: an adapter can never report, or draw, more yield than its own budget. `rescue` can
/// only take the part of the balance that no budget has claimed.
contract YieldReserve is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    ICityFactory public immutable factory;

    /// @notice Yield budget handed to each adapter that enrolls from now on.
    uint256 public defaultQuota;
    /// @notice Sum of every adapter's remaining budget. Always <= the reserve's balance.
    uint256 public totalAllocated;
    mapping(address adapter => uint256 remaining) public quotaOf;
    mapping(address adapter => bool) public enrolled;

    event Enrolled(address indexed adapter, uint256 granted);
    event QuotaGranted(address indexed adapter, uint256 amount);
    event DefaultQuotaSet(uint256 defaultQuota);
    event Paid(address indexed adapter, address indexed to, uint256 paid);
    event Shortfall(address indexed adapter, uint256 requested, uint256 available);
    event Rescued(address indexed to, uint256 amount);

    error NotAdapter(address caller);
    error AlreadyEnrolled(address adapter);
    error ExceedsUnallocated(uint256 requested, uint256 unallocated);

    constructor(address owner_, IERC20 asset_, ICityFactory factory_, uint256 defaultQuota_) Ownable(owner_) {
        asset = asset_;
        factory = factory_;
        defaultQuota = defaultQuota_;
        emit DefaultQuotaSet(defaultQuota_);
    }

    /// @notice Balance that no adapter budget has claimed yet.
    function unallocated() public view returns (uint256) {
        uint256 balance = asset.balanceOf(address(this));
        return balance > totalAllocated ? balance - totalAllocated : 0;
    }

    /// @notice Called once by a new adapter clone during initialisation. Grants it `defaultQuota`, or whatever is
    /// still unallocated if that is less (possibly zero; the owner can top it up later with `grantQuota`).
    function enroll() external returns (uint256 granted) {
        if (!factory.isAdapterClone(msg.sender)) revert NotAdapter(msg.sender);
        if (enrolled[msg.sender]) revert AlreadyEnrolled(msg.sender);
        enrolled[msg.sender] = true;
        uint256 free = unallocated();
        granted = defaultQuota < free ? defaultQuota : free;
        quotaOf[msg.sender] = granted;
        totalAllocated += granted;
        emit Enrolled(msg.sender, granted);
    }

    /// @notice Pays up to `amount` to `to`, limited by the caller's remaining budget, and returns what was paid.
    function pay(address to, uint256 amount) external returns (uint256 paid) {
        if (!enrolled[msg.sender]) revert NotAdapter(msg.sender);
        uint256 remaining = quotaOf[msg.sender];
        paid = amount < remaining ? amount : remaining;
        if (paid < amount) emit Shortfall(msg.sender, amount, remaining);
        if (paid > 0) {
            quotaOf[msg.sender] = remaining - paid;
            totalAllocated -= paid;
            asset.safeTransfer(to, paid);
            emit Paid(msg.sender, to, paid);
        }
    }

    /// @notice Platform tops up one adapter's budget from the unallocated balance.
    function grantQuota(address adapter, uint256 amount) external onlyOwner {
        if (!enrolled[adapter]) revert NotAdapter(adapter);
        uint256 free = unallocated();
        if (amount > free) revert ExceedsUnallocated(amount, free);
        quotaOf[adapter] += amount;
        totalAllocated += amount;
        emit QuotaGranted(adapter, amount);
    }

    function setDefaultQuota(uint256 quota) external onlyOwner {
        defaultQuota = quota;
        emit DefaultQuotaSet(quota);
    }

    /// @notice Platform can take back only what no adapter budget has claimed.
    function rescue(address to, uint256 amount) external onlyOwner {
        uint256 free = unallocated();
        if (amount > free) revert ExceedsUnallocated(amount, free);
        asset.safeTransfer(to, amount);
        emit Rescued(to, amount);
    }
}
