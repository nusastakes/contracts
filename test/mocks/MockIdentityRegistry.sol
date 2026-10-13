// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Test stand-in for the ERC-8004 Identity Registry: an ERC-721 whose agent wallet defaults to the registrant.
contract MockIdentityRegistry is ERC721 {
    uint256 public nextId;
    mapping(uint256 => address) private _wallet;

    constructor() ERC721("AgentIdentity", "AGENT") {}

    function register(address to) external returns (uint256 id) {
        id = nextId++;
        _wallet[id] = to;
        _mint(to, id);
    }

    function getAgentWallet(uint256 id) external view returns (address) {
        return _wallet[id];
    }

    function setWallet(uint256 id, address wallet) external {
        _wallet[id] = wallet;
    }
}
