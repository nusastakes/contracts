// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReceiverTemplate} from "./vendor/chainlink/ReceiverTemplate.sol";

/// @notice Receiver of Chainlink CRE reports with the extra checks our payloads need.
/// @dev A DON-signed report does not commit to the contract that receives it, and the forwarder routes a report to
/// whatever receiver the sending workflow names. So the forwarder check alone is not enough, and this base adds:
///  * the payload must name this contract (`target`) and the expected chain,
///  * reports are refused until the owner has pinned a workflow owner or workflow id, unless identity enforcement is
///    switched off on purpose (simulation only; the mock forwarder is permissionless).
/// The `ReceiverTemplate` owner is the deployer; hand it over with `transferOwnership` if needed.
abstract contract CreConsumer is ReceiverTemplate {
    bool public identityEnforced = true;
    uint64 public expectedChainSelector;

    event IdentityEnforcedSet(bool enforced);
    event ExpectedChainSelectorSet(uint64 chainSelector);

    error IdentityNotConfigured();
    error WrongTarget(address received);
    error WrongChain(uint64 received, uint64 expected);

    constructor(address forwarder, uint64 chainSelector) ReceiverTemplate(forwarder) {
        expectedChainSelector = chainSelector;
        emit ExpectedChainSelectorSet(chainSelector);
    }

    /// @notice Turn the "workflow identity must be pinned" rule off or on. Keep it on anywhere real money is at stake.
    function setIdentityEnforced(bool enforced) external onlyOwner {
        identityEnforced = enforced;
        emit IdentityEnforcedSet(enforced);
    }

    function setExpectedChainSelector(uint64 chainSelector) external onlyOwner {
        expectedChainSelector = chainSelector;
        emit ExpectedChainSelectorSet(chainSelector);
    }

    /// @dev Call first in `_processReport`, after decoding the payload.
    function _checkReport(address target, uint64 chainSelector) internal view {
        if (identityEnforced && this.getExpectedAuthor() == address(0) && this.getExpectedWorkflowId() == bytes32(0)) {
            revert IdentityNotConfigured();
        }
        if (target != address(this)) revert WrongTarget(target);
        if (chainSelector != expectedChainSelector) revert WrongChain(chainSelector, expectedChainSelector);
    }
}
