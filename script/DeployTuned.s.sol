// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {CityFactory} from "../src/CityFactory.sol";
import {TunedMirrorAdapter} from "../src/adapters/TunedMirrorAdapter.sol";

/// @notice One `TunedMirrorAdapter` implementation per catalog service that gives depositors something to tune in the
/// real protocol (reward tokens, a loop on a market that accepts the asset as collateral, a concentrated-liquidity
/// range). Params are the same as the plain mirror: (base sourceId = keccak256(DefiLlama pool id), feed, reserve).
/// The plain implementations stay allowed, so existing cities are untouched.
///
///   forge script script/DeployTuned.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast
contract DeployTuned is Script {
    address internal constant FACTORY = 0xDC9A322E95E7d9214fA794D39534a15B4aB3d9fF;
    address internal constant FEED = 0x3328AEbB57Ee0bc8d2C7f68468dEe6B9b50926b5;
    address internal constant RESERVE = 0x40e194d12BC3F6a6b26E8B7808f749c88281Ef96;

    function services() public pure returns (string[2][] memory s) {
        s = new string[2][](11);
        s[0] = ["aave-ausd", "d795cb4c-e30f-52c0-8447-bf0853763a20"];
        s[1] = ["euler-ausd", "e150c112-d6f3-42f5-8c8d-78580058e1fd"];
        s[2] = ["curvance-ausd", "90924439-8fb8-4e6a-afe3-9ba393e68fdc"];
        s[3] = ["neverland-ausd", "ba0f675f-9f14-407b-b278-66d8f59f49ca"];
        s[4] = ["accountable-ausd", "4baffdfd-8015-4713-bad4-10a199b30157"];
        s[5] = ["morpho-hyperusdc", "ec6a71a7-41ae-4e72-942f-b4bc99c3b3cb"];
        s[6] = ["upshift-earnausd", "e10580de-1ad2-4bbc-a0e8-ad4db95df4a3"];
        s[7] = ["curve-ausd-3pool", "ceb80408-8ab8-4293-b274-162efff518a6"];
        s[8] = ["balancer-avusd", "86d04138-6712-5be0-85f4-1d92331ca1d5"];
        s[9] = ["mento-ausd-usdm", "ce74b9e0-376d-45ea-b1a4-362de60c12ce"];
        s[10] = ["uniswap-wmon-usdc", "82b60bc0-ec94-561a-a9e4-c481d47746dd"];
    }

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(block.chainid == 10143, "testnet only: mirror adapters are simulations");
        CityFactory factory = CityFactory(FACTORY);
        require(factory.owner() == vm.addr(key), "deployer does not own the factory");
        string[2][] memory s = services();
        address[] memory impls = new address[](s.length);
        vm.startBroadcast(key);
        for (uint256 i; i < s.length; i++) {
            TunedMirrorAdapter impl = new TunedMirrorAdapter();
            impls[i] = address(impl);
            factory.setAllowedAdapter(address(impl), true);
            factory.setAdapterParams(address(impl), abi.encode(keccak256(bytes(s[i][1])), FEED, RESERVE));
        }
        vm.stopBroadcast();
        for (uint256 i; i < s.length; i++) console.log(string.concat("tuned ", s[i][0], " ", vm.toString(impls[i])));
    }
}
