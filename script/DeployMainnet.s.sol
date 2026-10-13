// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CityFactory} from "../src/CityFactory.sol";
import {CityGuardian} from "../src/CityGuardian.sol";
import {CityVault} from "../src/CityVault.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

/// @notice The R25 mainnet proof (backlog B4.8): a small, capped copy of the stack on Monad mainnet (chain 143) whose
/// one city invests in the real Morpho "Grove x Steakhouse High Yield AUSD" vault. Nothing here is simulated yield.
///
/// Safety rails, all enforced in code:
///  * refuses to run on any chain other than 143, and the key comes from MAINNET_DEPLOYER_PRIVATE_KEY, a different
///    variable from the testnet DEPLOYER_PRIVATE_KEY, so a testnet run can never reach mainnet by mistake;
///  * the city deposit cap is at most 200 AUSD (the limit in the plan), whatever DEPOSIT_CAP says;
///  * the target vault must exist, be an ERC-4626 and hold AUSD as its asset.
///
/// Nothing is sent without `--broadcast`:
///   forge script script/DeployMainnet.s.sol --rpc-url $MONAD_MAINNET_RPC                 # dry run on a fork
///   forge script script/DeployMainnet.s.sol --rpc-url $MONAD_MAINNET_RPC --broadcast      # real deploy (needs MON for gas)
///
/// The deployer is also the owner, the mayor and the platform treasury of this proof stack. Run MainnetProof.s.sol
/// afterwards with CITY set to the address this script logs.
contract DeployMainnet is Script {
    uint256 internal constant MONAD_MAINNET = 143;
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant GROVE = 0x32841A8511D5c2c5b253f45668780B99139e476D;
    /// @dev Chainlink chain selector of `monad-mainnet` (chainlink-evm SDK table).
    uint64 internal constant MONAD_MAINNET_SELECTOR = 8481857512324358265;
    uint256 internal constant MAX_PROOF_CAP = 200e6;

    struct Deployment {
        address deployer;
        CityGuardian guardian;
        CityFactory factory;
        ERC4626Adapter adapterImpl;
        CityVault city;
    }

    function run() external returns (Deployment memory) {
        uint256 deployerKey = vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        return deploy(
            deployerKey,
            vm.envOr("PLATFORM_TREASURY", deployer),
            // No Chainlink forwarder is pinned for the proof: with the deployer as forwarder and no workflow identity
            // set, the guardian refuses every report. Set CRE_FORWARDER only if the CRE guard should run on mainnet.
            vm.envOr("CRE_FORWARDER", deployer),
            vm.envOr("DEPOSIT_CAP", MAX_PROOF_CAP),
            vm.envOr("CITY_NAME", string("Nusastakes mainnet proof")),
            uint16(vm.envOr("CITY_FEE_BPS", uint256(1000)))
        );
    }

    /// @dev Public so the fork test can call it with explicit arguments instead of process-wide environment variables.
    function deploy(
        uint256 deployerKey,
        address treasury,
        address forwarder,
        uint256 depositCap,
        string memory cityName,
        uint16 feeBps
    ) public returns (Deployment memory d) {
        require(block.chainid == MONAD_MAINNET, "this script only runs on Monad mainnet (chain 143)");
        address deployer = vm.addr(deployerKey);

        require(depositCap > 0 && depositCap <= MAX_PROOF_CAP, "DEPOSIT_CAP must be between 1 and 200 AUSD (6 decimals)");
        require(AUSD.code.length > 0 && GROVE.code.length > 0, "AUSD or the Morpho vault has no code on this chain");
        require(IERC4626(GROVE).asset() == AUSD, "the Morpho vault does not hold AUSD");

        vm.startBroadcast(deployerKey);

        d.deployer = deployer;
        d.guardian = new CityGuardian(deployer, forwarder, MONAD_MAINNET_SELECTOR);
        d.factory = new CityFactory(deployer, IERC20(AUSD), treasury, address(d.guardian), depositCap);
        d.adapterImpl = new ERC4626Adapter();
        d.factory.setAllowedAdapter(address(d.adapterImpl), true);
        d.factory.setAdapterParams(address(d.adapterImpl), abi.encode(GROVE));

        address[] memory impls = new address[](1);
        impls[0] = address(d.adapterImpl);
        d.city = CityVault(d.factory.createCity(cityName, "", feeBps, impls, ""));

        vm.stopBroadcast();

        console.log("chainid          ", block.chainid);
        console.log("deployer / mayor ", deployer);
        console.log("CityGuardian     ", address(d.guardian));
        console.log("CityFactory      ", address(d.factory));
        console.log("ERC4626Adapter   ", address(d.adapterImpl));
        console.log("City (CITY=)     ", address(d.city));
        console.log("city adapter     ", d.city.adapters()[0]);
        console.log("deposit cap      ", depositCap);
    }
}
