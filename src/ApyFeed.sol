// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CreConsumer} from "./CreConsumer.sol";

/// @notice Onchain record of the APY of real mainnet vaults, written by a keeper EOA (`updater`) or by a validated
/// Chainlink CRE report. `MirrorYieldAdapter` earns this rate in the testnet demo, so the simulated yield follows
/// real markets. The keeper is the primary path; the CRE path stays closed until a workflow identity is pinned.
/// @dev Besides the latest value, the feed keeps a cumulative index (sum of apyBps x seconds) per source, so readers
/// can integrate yield exactly across rate changes without having to be touched at every update.
contract ApyFeed is CreConsumer {
    /// @dev Sanity ceiling: 5000 bps = 50% a year.
    uint32 public constant MAX_APY_BPS = 5000;

    struct Source {
        uint32 apyBps;
        uint64 observedAt;
        uint64 updatedAt;
        uint256 index;
    }

    address public updater;
    mapping(bytes32 => Source) private _sources;
    mapping(bytes32 => string) public sourceLabel;

    event ApySet(bytes32 indexed sourceId, uint32 apyBps, uint64 observedAt, string label);
    event UpdaterSet(address indexed updater);
    event SourceLabelSet(bytes32 indexed sourceId, string label);

    error NotUpdater();
    error ApyTooHigh(uint32 apyBps);
    error StaleObservation(uint64 observedAt, uint64 latest);
    error ObservationInFuture(uint64 observedAt);

    /// @dev The CRE receiver base makes the deployer the owner; ownership moves to `owner_` right away.
    constructor(address owner_, address updater_, address forwarder_, uint64 chainSelector_)
        CreConsumer(forwarder_, chainSelector_)
    {
        if (owner_ != msg.sender) transferOwnership(owner_);
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setUpdater(address updater_) external onlyOwner {
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setSourceLabel(bytes32 sourceId, string calldata label) external onlyOwner {
        sourceLabel[sourceId] = label;
        emit SourceLabelSet(sourceId, label);
    }

    /// @notice Records the APY observed for `sourceId` at `observedAt`. Callable only by the updater.
    function setApy(bytes32 sourceId, uint32 apyBps, uint64 observedAt) external {
        if (msg.sender != updater) revert NotUpdater();
        _setApy(sourceId, apyBps, observedAt);
    }

    function latest(bytes32 sourceId) external view returns (uint32 apyBps, uint64 observedAt, uint64 updatedAt) {
        Source storage s = _sources[sourceId];
        return (s.apyBps, s.observedAt, s.updatedAt);
    }

    /// @notice Cumulative sum of apyBps x seconds for `sourceId` up to now. The difference between two readings,
    /// times principal, divided by (365 days x 10_000), is the yield earned in between.
    function currentIndex(bytes32 sourceId) external view returns (uint256) {
        Source storage s = _sources[sourceId];
        return s.index + uint256(s.apyBps) * (block.timestamp - s.updatedAt);
    }

    /// @dev CRE report payload: abi.encode(address target, bytes32 sourceId, uint32 apyBps, uint64 observedAt,
    /// uint64 chainSelector). `observedAt` must be strictly newer than the stored one, so a report cannot be replayed.
    function _processReport(bytes calldata report) internal override {
        (address target, bytes32 sourceId, uint32 apyBps, uint64 observedAt, uint64 chainSelector) =
            abi.decode(report, (address, bytes32, uint32, uint64, uint64));
        _checkReport(target, chainSelector);
        uint64 stored = _sources[sourceId].observedAt;
        if (observedAt <= stored) revert StaleObservation(observedAt, stored);
        _setApy(sourceId, apyBps, observedAt);
    }

    function _setApy(bytes32 sourceId, uint32 apyBps, uint64 observedAt) internal {
        if (apyBps > MAX_APY_BPS) revert ApyTooHigh(apyBps);
        if (observedAt > block.timestamp) revert ObservationInFuture(observedAt);
        Source storage s = _sources[sourceId];
        if (observedAt < s.observedAt) revert StaleObservation(observedAt, s.observedAt);

        // The previous rate applied until now. A source that was never set has apyBps 0, so this adds nothing.
        if (s.updatedAt != 0) s.index += uint256(s.apyBps) * (block.timestamp - s.updatedAt);
        s.apyBps = apyBps;
        s.observedAt = observedAt;
        s.updatedAt = uint64(block.timestamp);

        emit ApySet(sourceId, apyBps, observedAt, sourceLabel[sourceId]);
    }
}
