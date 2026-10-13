// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ApyFeed} from "../src/ApyFeed.sol";
import {CityFactory} from "../src/CityFactory.sol";
import {CityServices} from "../src/CityServices.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {ICityFactory} from "../src/interfaces/ICityFactory.sol";
import {MirrorYieldAdapter} from "../src/adapters/MirrorYieldAdapter.sol";

/// @notice Adds the service catalog to an existing v3 deployment, without redeploying the factory:
///  1. one `MirrorYieldAdapter` implementation per catalog yield service (17), each mirroring the APY of one Monad
///     mainnet pool. `sourceId` = keccak256(DefiLlama pool id), the same hash the web app and the relayer use. The
///     factory allows each implementation and stores its params; the feed gets a readable label per source;
///  2. `CityServices` (the city's counter for outside users: launchpad now, prediction markets held back);
///  3. a smaller default yield budget per adapter clone, so one funded reserve serves many more cities.
///
///   forge script script/DeployServices.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast
///
/// Reads DEPLOYER_PRIVATE_KEY (owner of the factory, feed and reserve). Testnet only: the mirror adapters are
/// simulations and must never be allowed on a mainnet factory.
contract DeployServices is Script {
    address internal constant AUSD_TESTNET = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;
    address internal constant FACTORY = 0xDC9A322E95E7d9214fA794D39534a15B4aB3d9fF;
    address internal constant FEED = 0x3328AEbB57Ee0bc8d2C7f68468dEe6B9b50926b5;
    address internal constant RESERVE = 0x40e194d12BC3F6a6b26E8B7808f749c88281Ef96;

    uint256 internal constant LAUNCH_FEE = 1e6; // 1 AUSD
    uint256 internal constant VIRTUAL_RESERVE = 5_000e6; // starting price 5,000 AUSD / 1e9 tokens
    uint64 internal constant DRIP_PERIOD = 12 hours;
    uint256 internal constant DEFAULT_QUOTA = 200e6; // yield budget per adapter clone

    struct Source {
        string id;
        string pool;
        string label;
    }

    function sources() public pure returns (Source[] memory s) {
        s = new Source[](17);
        s[0] = Source("aave-ausd", "d795cb4c-e30f-52c0-8447-bf0853763a20", "Aave v3 AUSD (mainnet)");
        s[1] = Source("euler-ausd", "e150c112-d6f3-42f5-8c8d-78580058e1fd", "Euler v2 eAUSD (mainnet)");
        s[2] = Source("curvance-ausd", "90924439-8fb8-4e6a-afe3-9ba393e68fdc", "Curvance AUSD (mainnet)");
        s[3] = Source("upshift-earnausd", "e10580de-1ad2-4bbc-a0e8-ad4db95df4a3", "Upshift earnAUSD (mainnet)");
        s[4] = Source("curve-ausd-3pool", "ceb80408-8ab8-4293-b274-162efff518a6", "Curve AUSD/USDC/USDT0 (mainnet)");
        s[5] = Source("balancer-avusd", "86d04138-6712-5be0-85f4-1d92331ca1d5", "Balancer v3 AVUSD/AUSD (mainnet)");
        s[6] = Source("shmonad", "ee40513c-9356-4c53-9f26-446b484a8ae2", "ShMonad staking MON (mainnet)");
        s[7] = Source("accountable-ausd", "4baffdfd-8015-4713-bad4-10a199b30157", "Accountable AUSD (mainnet)");
        s[8] = Source("neverland-ausd", "ba0f675f-9f14-407b-b278-66d8f59f49ca", "Neverland AUSD (mainnet)");
        s[9] = Source("morpho-hyperusdc", "ec6a71a7-41ae-4e72-942f-b4bc99c3b3cb", "Morpho HyperUSDC (mainnet)");
        s[10] = Source("yuzu-syzusd", "c51e151e-44ad-4f25-9911-102bd00811dc", "Yuzu Money syzUSD (mainnet)");
        s[11] = Source("beefy-usdc", "70f959a9-0167-54b4-a89b-53e35d75cd8e", "Beefy USDC (mainnet)");
        s[12] = Source("infinifi-siusd", "9d102f42-e9e8-51dc-9eb4-83e1b02ccd1e", "infiniFi siUSD (mainnet)");
        s[13] = Source("pendle-ausd-fixed", "653d8a8d-d221-5482-884b-1f936df4cd9e", "Pendle v2 PT-AUSD fixed rate (mainnet)");
        s[14] = Source("mento-ausd-usdm", "ce74b9e0-376d-45ea-b1a4-362de60c12ce", "Mento AUSD/USDm (mainnet)");
        s[15] = Source("uniswap-wmon-usdc", "82b60bc0-ec94-561a-a9e4-c481d47746dd", "Uniswap v3 WMON/USDC (mainnet, volatile)");
        s[16] = Source("kintsu-smon", "73c511a9-4dc0-4397-babe-e578fd75f0dd", "Kintsu sMON staking MON (mainnet)");
    }

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(block.chainid == 10143, "testnet only: mirror adapters are simulations");
        CityFactory factory = CityFactory(FACTORY);
        ApyFeed feed = ApyFeed(FEED);
        YieldReserve reserve = YieldReserve(RESERVE);
        require(factory.owner() == vm.addr(key), "deployer does not own the factory");

        Source[] memory s = sources();
        address[] memory impls = new address[](s.length);

        vm.startBroadcast(key);
        for (uint256 i; i < s.length; i++) {
            bytes32 sourceId = keccak256(bytes(s[i].pool));
            MirrorYieldAdapter impl = new MirrorYieldAdapter();
            impls[i] = address(impl);
            factory.setAllowedAdapter(address(impl), true);
            factory.setAdapterParams(address(impl), abi.encode(sourceId, FEED, RESERVE));
            feed.setSourceLabel(sourceId, s[i].label);
        }
        CityServices services = new CityServices(
            IERC20(AUSD_TESTNET), ICityFactory(FACTORY), feed, LAUNCH_FEE, VIRTUAL_RESERVE, DRIP_PERIOD, false
        );
        reserve.setDefaultQuota(DEFAULT_QUOTA);
        vm.stopBroadcast();

        console.log("CityServices", address(services));
        for (uint256 i; i < s.length; i++) {
            console.log(string.concat("impl ", s[i].id, " ", vm.toString(impls[i]), " ", vm.toString(keccak256(bytes(s[i].pool)))));
        }
    }
}
