// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "./Base.t.sol";
import {CityVault} from "../src/CityVault.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";

/// @dev Random sequences of everything that can happen around a quarantine: deposits, exits, yield, adapters breaking and
/// healing, quarantine and restore, and money moved in and out by the mayor and the guardian, including out of an adapter
/// that is in quarantine. The independent review found the "phantom assets" bug (money counted twice) with exactly this
/// kind of sequence; the books must never show more than what is really there.
contract QuarantineHandler {
    CityVault internal vault;
    MockYieldAdapter internal adapterA;
    MockYieldAdapter internal adapterB;
    address internal mayor;
    address internal guardian;
    address[] internal actors;
    uint256 public steps;
    /// @dev Set when the high-water mark fell although shares existed before and after a step. It may only fall to zero supply.
    bool public hwmDropped;

    modifier track() {
        uint256 hwmBefore = vault.highWaterMark();
        uint256 supplyBefore = vault.totalSupply();
        _;
        if (supplyBefore > 0 && vault.totalSupply() > 0 && vault.highWaterMark() < hwmBefore) hwmDropped = true;
    }

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    constructor(CityVault v, MockYieldAdapter a, MockYieldAdapter b, address mayor_, address guardian_) {
        vault = v;
        adapterA = a;
        adapterB = b;
        mayor = mayor_;
        guardian = guardian_;
    }

    function addActor(address who) external {
        actors.push(who);
    }

    function _adapter(uint256 seed) internal view returns (MockYieldAdapter) {
        return seed % 2 == 0 ? adapterA : adapterB;
    }

    function deposit(uint256 actorSeed, uint256 amount) external track {
        steps++;
        address who = actors[actorSeed % actors.length];
        amount = amount % 1_000_000e6;
        if (amount == 0) return;
        address token = vault.asset();
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", who, amount));
        if (!ok) return;
        vm.startPrank(who);
        token.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), amount));
        try vault.deposit(amount, who) {} catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external track {
        steps++;
        address who = actors[actorSeed % actors.length];
        uint256 shares = (vault.balanceOf(who) * (fractionBps % 10_001)) / 10_000;
        if (shares == 0) return;
        vm.prank(who);
        try vault.redeem(shares, who, who) {} catch {}
    }

    function yieldIn(uint256 seed, uint256 amount) external track {
        steps++;
        _adapter(seed).addYield(amount % 100_000e6);
    }

    function harvest() external track {
        steps++;
        try vault.harvestFee() {} catch {}
    }

    function breakAdapter(uint256 seed, uint256 mode) external track {
        steps++;
        // Revert or garbage return. Gas-burning adapters are covered by their own unit test: inside a random sequence they
        // make every pricing call burn the whole gas limit and the run takes forever.
        _adapter(seed).setMode(uint8(1 + (mode % 2)));
    }

    function healAdapter(uint256 seed) external track {
        steps++;
        _adapter(seed).setMode(0);
    }

    function quarantine(uint256 seed) external track {
        steps++;
        try vault.quarantine{gas: 1_300_000}(address(_adapter(seed))) {} catch {}
    }

    function restore(uint256 seed) external track {
        steps++;
        try vault.restoreAdapter(address(_adapter(seed))) {} catch {}
    }

    function moveOut(uint256 seed, uint256 amount) external track {
        steps++;
        MockYieldAdapter a = _adapter(seed);
        uint256 held = a.mode() == 0 || vault.quarantined(address(a)) ? _balanceOf(address(a)) : 0;
        if (held == 0) return;
        vm.prank(mayor);
        try vault.rebalance(address(a), address(0), 1 + (amount % held), bytes32(0)) {} catch {}
    }

    function moveIn(uint256 seed, uint256 amount) external track {
        steps++;
        MockYieldAdapter a = _adapter(seed);
        uint256 idle = _balanceOf(address(vault));
        if (idle == 0) return;
        vm.prank(mayor);
        try vault.rebalance(address(0), address(a), 1 + (amount % idle), bytes32(0)) {} catch {}
    }

    function evacuate(uint256 seed) external track {
        steps++;
        vm.prank(guardian);
        try vault.evacuate(address(_adapter(seed))) {} catch {}
    }

    function _balanceOf(address who) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = vault.asset().staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (ok) bal = abi.decode(ret, (uint256));
    }
}

contract CityVaultV3InvariantTest is StdInvariant, BaseTest {
    QuarantineHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new QuarantineHandler(vault, adapterA, adapterB, mayor, guardianAddr);
        handler.addActor(alice);
        handler.addActor(bob);
        handler.addActor(carol);
        targetContract(address(handler));
    }

    function _idle() internal view returns (uint256) {
        return asset.balanceOf(address(vault));
    }

    /// The books never show more than the money that exists, and while the pricing works they equal idle plus the healthy
    /// adapters exactly (a quarantined adapter counts as zero).
    function invariant_BooksNeverExceedWhatIsReallyThere() public view {
        uint256 real = _idle() + asset.balanceOf(address(adapterA)) + asset.balanceOf(address(adapterB));
        uint256 expected = _idle();
        if (!vault.quarantined(address(adapterA))) expected += asset.balanceOf(address(adapterA));
        if (!vault.quarantined(address(adapterB))) expected += asset.balanceOf(address(adapterB));
        try vault.totalAssets() returns (uint256 books) {
            assertLe(books, real, "the books show money that is not there");
            assertEq(books, expected, "books = idle + healthy adapters, a quarantined adapter counts as zero");
        } catch {
            // Pricing reverts only while an unquarantined adapter is failing, which anyone can end with quarantine().
            bool aFailing = adapterA.mode() != 0 && !vault.quarantined(address(adapterA));
            bool bFailing = adapterB.mode() != 0 && !vault.quarantined(address(adapterB));
            assertTrue(aFailing || bFailing, "pricing reverted with every adapter healthy or quarantined");
        }
    }

    /// From the third review: a restore or a quarantine must never lower the high-water mark while holders exist, or the
    /// mayor and the treasury would be paid the same profit twice. (A mutant that re-based it was invisible to the accounting
    /// invariant above.)
    function invariant_HighWaterMarkNeverFallsWhileHoldersExist() public view {
        assertFalse(handler.hwmDropped(), "the high-water mark fell while shares existed");
    }

    function invariant_QuarantineCountMatchesTheFlags() public view {
        uint256 n = (vault.quarantined(address(adapterA)) ? 1 : 0) + (vault.quarantined(address(adapterB)) ? 1 : 0);
        assertEq(vault.quarantinedCount(), n);
    }
}
