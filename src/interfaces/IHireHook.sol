// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Implemented by a contract that wants to act when somebody hires an agent through `AgentMarketplace`.
/// @dev The marketplace calls it after payment, with `client` set to the account that paid. A hook must only trust the call
/// if `msg.sender` is the marketplace it expects (as `CityGuardian.onHire` does), because anyone can name any hook.
/// `expiry` is the end of *this* payment counted from now; a hook that wants renewals to add up (as the guardian does) has to
/// extend its own record, because the marketplace's chained end date is not passed in.
interface IHireHook {
    function onHire(address client, address agent, bytes32 capability, uint64 expiry, bytes calldata data) external;
}
