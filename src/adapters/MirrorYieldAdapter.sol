// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AdapterBase} from "./AdapterBase.sol";
import {ApyFeed} from "../ApyFeed.sol";
import {YieldReserve} from "../YieldReserve.sol";

/// @notice SIMULATED yield for networks where no real protocol accepts the asset. It earns the APY that `ApyFeed`
/// reports for a mainnet source (for example a Morpho AUSD vault) and pays that yield out of `YieldReserve`, within the
/// yield budget (`quotaOf`) the reserve reserved for this adapter. Nothing is lent anywhere. The UI and README must
/// always call it a simulation.
/// @dev Yield is integrated against the feed's cumulative index, so an APY change in the middle of a period is
/// applied only from the moment the feed was updated, even if nobody touched this adapter in between.
contract MirrorYieldAdapter is AdapterBase {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant YEAR_BPS = 365 days * 10_000;

    ApyFeed public feed;
    YieldReserve public reserve;
    bytes32 public sourceId;

    /// @notice Assets held by this adapter (deposits plus yield already paid out of the reserve).
    uint256 public principal;
    /// @notice Yield earned but not yet paid because the reserve was short.
    uint256 public owed;
    uint256 public lastIndex;

    /// @dev params = abi.encode(bytes32 sourceId, address feed, address reserve). Enrolling with the reserve fails
    /// loudly if the reserve belongs to another factory, so a misconfigured platform cannot found a city.
    function _init(bytes calldata params) internal virtual override {
        (bytes32 sourceId_, address feed_, address reserve_) = abi.decode(params, (bytes32, address, address));
        sourceId = sourceId_;
        feed = ApyFeed(feed_);
        reserve = YieldReserve(reserve_);
        lastIndex = feed.currentIndex(sourceId_);
        reserve.enroll();
    }

    function isSimulated() external pure returns (bool) {
        return true;
    }

    function deposit(uint256 assets) external onlyVault {
        _settle();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        principal += assets;
    }

    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        _settle();
        withdrawn = assets < principal ? assets : principal;
        principal -= withdrawn;
        IERC20(asset).safeTransfer(vault, withdrawn);
    }

    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        _settle();
        withdrawn = principal;
        principal = 0;
        IERC20(asset).safeTransfer(vault, withdrawn);
    }

    /// @notice Principal plus yield earned so far, never more than principal plus this adapter's remaining budget in
    /// the reserve. Budgets of different adapters never overlap, so summing over cities cannot count a coin twice.
    function totalAssets() external view returns (uint256) {
        uint256 claim = owed + _pending(feed.currentIndex(sourceId));
        uint256 budget;
        try reserve.quotaOf(address(this)) returns (uint256 q) {
            budget = q;
        } catch {}
        return principal + (claim < budget ? claim : budget);
    }

    function _pending(uint256 index) internal view returns (uint256) {
        return principal.mulDiv(index - lastIndex, YEAR_BPS);
    }

    /// @dev Books yield earned since the last touch and pulls whatever the reserve can pay into this adapter. A
    /// failing reserve must never trap the principal, so its failure only leaves the yield unpaid.
    function _settle() internal {
        uint256 index = feed.currentIndex(sourceId);
        owed += _pending(index);
        lastIndex = index;
        if (owed > 0) {
            try reserve.pay(address(this), owed) returns (uint256 paid) {
                owed -= paid;
                principal += paid;
            } catch {}
        }
    }
}
