// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MirrorYieldAdapter} from "./MirrorYieldAdapter.sol";

interface ICityVaultSession {
    function mayor() external view returns (address);
    function sessionKey() external view returns (address);
    function sessionKeyExpiry() external view returns (uint64);
}

/// @notice SIMULATED yield, like `MirrorYieldAdapter`, but each city tunes its own position the way a depositor could
/// in the real protocol (for example the loop multiple on a lending market that accepts the asset as collateral, taking
/// reward tokens or only the base rate, or the price range of a concentrated-liquidity position). The tuning is stored
/// here and only the city's mayor or the mayor's active session key may change it.
/// @dev The adapter earns the APY that `ApyFeed` reports under its OWN key (`sourceId` = keccak256("nusastakes.tuned",
/// this)), which the platform keeper computes from this adapter's tuning and the live mainnet data of `baseSourceId`
/// with a published formula. Until the keeper writes it, the adapter earns nothing. A tuning that would lose money in
/// the real protocol is written as 0: the feed cannot express a negative rate (the UI says so).
contract TunedMirrorAdapter is MirrorYieldAdapter {
    uint256 public constant MAX_TUNING_BYTES = 256;

    /// @notice The mainnet pool this service mirrors (keccak256 of the DefiLlama pool id), as for the plain mirror.
    bytes32 public baseSourceId;
    /// @notice The city's current tuning, ABI-encoded as the service's knob schema says (see the relayer catalog).
    bytes public tuning;
    uint64 public tunedAt;

    event TuningSet(address indexed vault, address indexed by, bytes tuning);

    error NotMayorOrSessionKey();
    error TuningTooLong();

    function _init(bytes calldata params) internal override {
        super._init(params);
        baseSourceId = sourceId;
        bytes32 own = keccak256(abi.encode("nusastakes.tuned", address(this)));
        sourceId = own;
        lastIndex = feed.currentIndex(own);
    }

    /// @notice Changes the tuning. Yield accrued so far is settled first at the old rate.
    function setTuning(bytes calldata newTuning) external {
        ICityVaultSession v = ICityVaultSession(vault);
        if (msg.sender != v.mayor() && !(msg.sender == v.sessionKey() && block.timestamp < v.sessionKeyExpiry())) {
            revert NotMayorOrSessionKey();
        }
        if (newTuning.length > MAX_TUNING_BYTES) revert TuningTooLong();
        _settle();
        tuning = newTuning;
        tunedAt = uint64(block.timestamp);
        emit TuningSet(vault, msg.sender, newTuning);
    }
}
