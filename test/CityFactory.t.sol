// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./Base.t.sol";
import {CityFactory} from "../src/CityFactory.sol";
import {CityVault} from "../src/CityVault.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

contract CityFactoryTest is BaseTest {
    event CityCreated(
        address indexed vault, address indexed mayor, string name, string community, uint16 feeBps, string mapURI
    );

    function _impls(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function test_AnyoneCanFoundACityAndBecomesMayor() public {
        vm.recordLogs();
        vm.prank(bob);
        address v = factory.createCity("Jogja", "Web3 Jogja", 500, _impls(address(implA)), "ipfs://jogja");
        CityVault city = CityVault(v);

        assertEq(city.mayor(), bob);
        assertEq(city.feeBps(), 500);
        assertEq(city.guardian(), guardianAddr);
        assertTrue(factory.isCity(v));
        assertEq(factory.cityCount(), 2); // setUp created one
        assertEq(factory.cityAt(1), v);
        assertEq(city.adapters().length, 1);
        assertTrue(factory.isAdapterClone(city.adapters()[0]));
        assertEq(MockYieldAdapter(city.adapters()[0]).vault(), v);
    }

    function test_CityCreatedEventCarriesTheDetails() public {
        // The vault address is not known in advance, so check topics 2 (mayor) and the data only.
        vm.expectEmit(false, true, false, false);
        emit CityCreated(address(0), bob, "Jogja", "Web3 Jogja", 500, "ipfs://jogja");
        vm.prank(bob);
        factory.createCity("Jogja", "Web3 Jogja", 500, _impls(address(implA)), "ipfs://jogja");
    }

    function test_EachCityGetsItsOwnAdapterClones() public {
        CityVault other = _createCity(bob, 500);
        assertTrue(other.adapters()[0] != vault.adapters()[0]);
        assertTrue(other.adapters()[1] != vault.adapters()[1]);
        assertEq(MockYieldAdapter(other.adapters()[0]).vault(), address(other));
    }

    function test_RejectsAdapterThePlatformDidNotAllow() public {
        MockYieldAdapter rogue = new MockYieldAdapter();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CityFactory.AdapterNotAllowed.selector, address(rogue)));
        factory.createCity("Rogue", "", 0, _impls(address(rogue)), "");

        vm.prank(owner);
        factory.setAllowedAdapter(address(implA), false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CityFactory.AdapterNotAllowed.selector, address(implA)));
        factory.createCity("Revoked", "", 0, _impls(address(implA)), "");
    }

    function test_RejectsDuplicatesTooManyAndEmptyName() public {
        address[] memory dup = new address[](2);
        dup[0] = address(implA);
        dup[1] = address(implA);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CityFactory.DuplicateAdapter.selector, address(implA)));
        factory.createCity("Dup", "", 0, dup, "");

        address[] memory many = new address[](9);
        vm.prank(bob);
        vm.expectRevert(CityFactory.TooManyAdapters.selector);
        factory.createCity("Many", "", 0, many, "");

        vm.prank(bob);
        vm.expectRevert(CityFactory.EmptyName.selector);
        factory.createCity("", "", 0, _impls(address(implA)), "");
    }

    function test_CityInfosReturnsEverythingTheCityListNeedsInOneCall() public {
        _deposit(alice, 1000 * UNIT);
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterA), 500 * UNIT, bytes32(0));
        adapterA.addYield(100 * UNIT);
        vm.prank(bob);
        address second = factory.createCity("Jogja", "Web3 Jogja", 500, _impls(address(implA)), "ipfs://jogja");

        CityFactory.CityInfo[] memory infos = factory.cityInfos(0, 10);
        assertEq(infos.length, 2);
        assertEq(infos[0].vault, address(vault));
        assertEq(infos[0].mayor, mayor);
        assertEq(infos[0].name, "Jakarta");
        assertEq(infos[0].community, "ETHJKT");
        assertEq(infos[0].mapURI, "ipfs://map");
        assertEq(infos[0].feeBps, 1000);
        assertEq(infos[0].totalAssets, 1100 * UNIT);
        assertEq(infos[0].adapters.length, 2);
        // net of the pending 10% fee: about 1.09x the starting price of 1e18
        assertApproxEqAbs(infos[0].pricePerShare, 1.09e18, 1e12);

        assertEq(infos[1].vault, second);
        assertEq(infos[1].mayor, bob);
        assertEq(infos[1].pricePerShare, 1e18, "a new city starts at exactly 1e18");
        assertEq(infos[1].totalSupply, 0);
    }

    function test_CityInfosPaging() public {
        _createCity(bob, 500);
        _createCity(carol, 500);
        assertEq(factory.cityInfos(1, 1).length, 1);
        assertEq(factory.cityInfos(1, 1)[0].mayor, bob);
        assertEq(factory.cityInfos(2, 100).length, 1, "three cities in total; count past the end is cut short");
        assertEq(factory.cityInfos(3, 5).length, 0);
        assertEq(factory.cityInfos(99, 5).length, 0, "start past the end is empty, not a revert");
    }

    function test_CityWithNoAdaptersIsAllowed() public {
        address[] memory none = new address[](0);
        vm.prank(bob);
        CityVault city = CityVault(factory.createCity("Idle only", "", 0, none, ""));
        assertEq(city.adapters().length, 0);
    }

    function test_OnlyOwnerSetsAllowedAdaptersAndLimits() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setAllowedAdapter(address(implA), false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setAdapterParams(address(implA), "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setPlatformTreasury(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setPlatformCutBps(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setMaxFeeBps(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setGuardian(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setDepositCap(1);
        vm.stopPrank();
    }

    function test_AllowingAnAddressWithoutCodeFails() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CityFactory.NoCode.selector, bob));
        factory.setAllowedAdapter(bob, true);
    }

    function test_PlatformCutAndGuardianAreFixedPerCityAtCreation() public {
        vm.startPrank(owner);
        factory.setPlatformCutBps(2500);
        factory.setGuardian(makeAddr("newGuardian"));
        vm.stopPrank();

        assertEq(vault.platformCutBps(), 1000, "existing city keeps its cut");
        assertEq(vault.guardian(), guardianAddr, "existing city keeps its guardian");

        CityVault fresh = _createCity(bob, 500);
        assertEq(fresh.platformCutBps(), 2500);
        assertEq(fresh.guardian(), makeAddr("newGuardian"));
    }

    function test_CeilingsProtectMayorsAndResidents() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CityFactory.BpsTooHigh.selector, uint16(5001), uint16(5000)));
        factory.setMaxFeeBps(5001);
        vm.expectRevert(abi.encodeWithSelector(CityFactory.BpsTooHigh.selector, uint16(5001), uint16(5000)));
        factory.setPlatformCutBps(5001);
        factory.setMaxFeeBps(5000);
        vm.stopPrank();
    }

    function test_ZeroAddressesAreRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(CityFactory.ZeroAddress.selector);
        factory.setPlatformTreasury(address(0));
        vm.expectRevert(CityFactory.ZeroAddress.selector);
        factory.setGuardian(address(0));
        vm.stopPrank();

        vm.expectRevert(CityFactory.ZeroAddress.selector);
        new CityFactory(owner, asset, address(0), guardianAddr, 1);
    }

    function test_FeeSharesGoToTheCurrentTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        factory.setPlatformTreasury(newTreasury);

        _deposit(alice, 1000 * UNIT);
        vm.prank(mayor);
        vault.rebalance(address(0), address(adapterA), 500 * UNIT, bytes32(0));
        adapterA.addYield(100 * UNIT);
        vault.harvestFee();

        assertGt(vault.balanceOf(newTreasury), 0);
        assertEq(vault.balanceOf(treasury), 0);
    }
}
