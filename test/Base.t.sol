// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CityFactory} from "../src/CityFactory.sol";
import {CityVault} from "../src/CityVault.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

/// @notice Shared setup: a 6-decimal permit token standing in for AUSD, a factory with two mock adapter
/// implementations allowed, and one city ("Jakarta", 10% fee, both adapters) founded by `mayor`.
abstract contract BaseTest is Test {
    uint256 internal constant UNIT = 1e6;

    MockERC20Permit internal asset;
    CityFactory internal factory;
    MockYieldAdapter internal implA;
    MockYieldAdapter internal implB;
    CityVault internal vault;
    MockYieldAdapter internal adapterA;
    MockYieldAdapter internal adapterB;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal guardianAddr = makeAddr("guardian");
    address internal mayor = makeAddr("mayor");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal relayer = makeAddr("relayer");
    address internal sessionKey = makeAddr("sessionKey");
    address internal alice;
    uint256 internal alicePk;

    function setUp() public virtual {
        (alice, alicePk) = makeAddrAndKey("alice");
        asset = new MockERC20Permit();
        factory = new CityFactory(owner, asset, treasury, guardianAddr, 1_000_000_000 * UNIT);
        implA = new MockYieldAdapter();
        implB = new MockYieldAdapter();
        vm.startPrank(owner);
        factory.setAllowedAdapter(address(implA), true);
        factory.setAllowedAdapter(address(implB), true);
        vm.stopPrank();

        vault = _createCity(mayor, 1000);
        address[] memory list = vault.adapters();
        adapterA = MockYieldAdapter(list[0]);
        adapterB = MockYieldAdapter(list[1]);
    }

    function _createCity(address founder, uint16 feeBps) internal returns (CityVault) {
        address[] memory impls = new address[](2);
        impls[0] = address(implA);
        impls[1] = address(implB);
        vm.prank(founder);
        return CityVault(factory.createCity("Jakarta", "ETHJKT", feeBps, impls, "ipfs://map"));
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _assetsOf(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    function _move(address from, address to, uint256 amount) internal {
        vm.prank(mayor);
        vault.rebalance(from, to, amount, keccak256("plan"));
    }

    function _signPermit(uint256 pk, address tokenOwner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 typeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(typeHash, tokenOwner, spender, value, asset.nonces(tokenOwner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", asset.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }
}
