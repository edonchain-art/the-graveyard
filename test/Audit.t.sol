// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GraveyardRaffle} from "../src/GraveyardRaffle.sol";
import {MockZombies, MockVRFWrapper, MerkleHelper} from "./GraveyardRaffle.t.sol";

/// Regression tests for the issues found in the 2026-10-23 audit. Each test replays the
/// original attack and checks that it now fails.
contract AuditTest is Test, MerkleHelper {
    address owner = makeAddr("owner");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");

    MockZombies zombies;
    MockVRFWrapper wrapper;
    GraveyardRaffle raffle;

    address[] holders;
    uint256[] tickets;
    bytes32[] leaves;

    function setUp() public {
        zombies = new MockZombies();
        wrapper = new MockVRFWrapper();
        vm.prank(owner);
        raffle = new GraveyardRaffle(address(wrapper), address(zombies));
        zombies.mint(owner, 1118);
        _ticket(victim, 1); // index 0
        _ticket(attacker, 2); // index 1
        for (uint256 i = 3; i <= 10; ++i) {
            _ticket(makeAddr(string(abi.encode(i))), i);
        }
    }

    function _ticket(address h, uint256 tokenId) internal {
        zombies.mint(h, tokenId);
        leaves.push(_leaf(holders.length, h, tokenId));
        holders.push(h);
        tickets.push(tokenId);
    }

    function _openAndCommit() internal {
        vm.prank(owner);
        zombies.safeTransferFrom(owner, address(raffle), 1118, abi.encode(uint64(block.timestamp + 1)));
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        raffle.commitEntrants(0, _root(leaves), uint32(leaves.length), "x");
    }

    /// Finding 1 (high): buying the drawn Zombie after the random word is public used to void
    /// the winner's ticket and hand the prize to the next ticket. Now the snapshot holder wins.
    function test_fixed_buyingDrawnZombieCannotStealPrize() public {
        uint256 word;
        while (uint256(keccak256(abi.encode(word))) % leaves.length != 0) ++word; // victim's ticket wins

        _openAndCommit();
        uint256 req = raffle.requestDraw{value: wrapper.PRICE()}(0);
        wrapper.fulfill(req, word);
        assertEq(raffle.drawnIndex(0), 0);

        // attacker buys the victim's Zombie before anyone settles
        vm.prank(victim);
        zombies.transferFrom(victim, attacker, 1);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.WrongIndex.selector, uint32(0)));
        raffle.settle(0, 1, attacker, 2, _proof(leaves, 1));
        vm.expectRevert(GraveyardRaffle.InvalidProof.selector);
        raffle.settle(0, 0, attacker, 1, _proof(leaves, 0));
        raffle.settle(0, 0, victim, 1, _proof(leaves, 0));
        vm.stopPrank();
        assertEq(zombies.ownerOf(1118), victim, "prize goes to the snapshot holder");
    }

    /// Finding 3 (low): renouncing ownership could strand an open giveaway. Now disabled.
    function test_fixed_renounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffle.RenounceDisabled.selector);
        raffle.renounceOwnership();
        assertEq(raffle.owner(), owner);
    }

    /// Finding 4 (low): Zombies sent with plain transferFrom were stuck. Now rescuable,
    /// but never while they are the prize of an unfinished giveaway.
    function test_fixed_rescueMistakenTransfer_butNeverALockedPrize() public {
        zombies.mint(owner, 2000);
        vm.prank(owner);
        zombies.transferFrom(owner, address(raffle), 2000);
        vm.prank(attacker);
        vm.expectRevert();
        raffle.rescueToken(address(zombies), 2000);
        vm.prank(owner);
        raffle.rescueToken(address(zombies), 2000);
        assertEq(zombies.ownerOf(2000), owner);

        // other collections too
        MockZombies other = new MockZombies();
        other.mint(owner, 5);
        vm.prank(owner);
        other.transferFrom(owner, address(raffle), 5);
        vm.prank(owner);
        raffle.rescueToken(address(other), 5);
        assertEq(other.ownerOf(5), owner);

        // the live prize can't be pulled out, at any stage
        _openAndCommit();
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffle.PrizeLocked.selector);
        raffle.rescueToken(address(zombies), 1118);
        uint256 req = raffle.requestDraw{value: wrapper.PRICE()}(0);
        wrapper.fulfill(req, 1);
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffle.PrizeLocked.selector);
        raffle.rescueToken(address(zombies), 1118);
    }

    /// Finding 5 (low): randomness could be re-requested after a day. Now never.
    function test_fixed_noReRequest() public {
        _openAndCommit();
        uint256 price = wrapper.PRICE();
        raffle.requestDraw{value: price}(0);
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.WrongStatus.selector, GraveyardRaffle.Status.Drawing));
        raffle.requestDraw{value: price}(0);
    }
}
