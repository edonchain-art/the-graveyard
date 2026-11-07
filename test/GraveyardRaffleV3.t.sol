// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721, ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {GraveyardRaffleV3} from "../src/GraveyardRaffleV3.sol";
import {MockVRFWrapper} from "./GraveyardRaffle.t.sol";

contract MockZombiesEnumV3 is ERC721Enumerable {
    bool public blockTransfers;

    constructor() ERC721("Zombies On Base", "ZOB") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setBlockTransfers(bool b) external {
        blockTransfers = b;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        require(!blockTransfers || auth == address(0), "blocked");
        return super._update(to, tokenId, auth);
    }
}

/// An owner wallet that refuses ETH (to prove it can't block draws).
contract RejectingOwnerV3 {
    function deploy(address wrapper, address zombies) external returns (GraveyardRaffleV3) {
        return new GraveyardRaffleV3(wrapper, zombies);
    }

    function approveAndStart(GraveyardRaffleV3 r, MockZombiesEnumV3 z, uint256 id, uint64 closesAt) external payable {
        z.setApprovalForAll(address(r), true);
        r.startGiveaway{value: msg.value}(id, closesAt, 1);
    }
}

contract GraveyardRaffleV3Test is Test {
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    MockZombiesEnumV3 zombies;
    MockVRFWrapper wrapper;
    GraveyardRaffleV3 raffle;

    uint256 constant PRIZE = 1118;
    uint256 constant DEPOSIT = 0.001 ether;

    function setUp() public {
        zombies = new MockZombiesEnumV3();
        wrapper = new MockVRFWrapper();
        vm.prank(owner);
        raffle = new GraveyardRaffleV3(address(wrapper), address(zombies));

        zombies.mint(alice, 1);
        zombies.mint(alice, 2);
        zombies.mint(bob, 3);
        zombies.mint(owner, 4); // owner-held: never a winner
        zombies.mint(owner, PRIZE);
        vm.prank(owner);
        zombies.setApprovalForAll(address(raffle), true);
        vm.deal(owner, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    function _start(uint64 closesIn) internal returns (uint256 id) {
        vm.prank(owner);
        id = raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp + closesIn), 1);
    }

    function _pick(uint256 word, uint32 attempt, uint256 count) internal view returns (uint256) {
        return zombies.tokenByIndex(uint256(keccak256(abi.encode(word, attempt))) % count);
    }

    function test_twoPressFlow() public {
        uint256 id = _start(1 days);
        assertEq(zombies.ownerOf(PRIZE), address(raffle));
        assertEq(raffle.lockedFees(), DEPOSIT);
        assertTrue(raffle.isLockedPrize(PRIZE));

        vm.prank(stranger);
        vm.expectRevert(GraveyardRaffleV3.StillOpen.selector);
        raffle.draw(id);

        vm.warp(block.timestamp + 1 days);
        uint256 ownerBefore = owner.balance;
        vm.prank(stranger);
        uint256 req = raffle.draw(id); // no ETH needed: the deposit pays
        assertEq(owner.balance - ownerBefore, DEPOSIT - wrapper.PRICE(), "unused deposit refunded to owner");
        assertEq(raffle.lockedFees(), 0);
        assertEq(raffle.getGiveaway(id).ticketCount, 5);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(GraveyardRaffleV3.WrongStatus.selector, GraveyardRaffleV3.Status.Drawing)
        );
        raffle.draw(id); // never re-requested

        wrapper.fulfill(req, 777);
        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Completed));
        assertTrue(g.winner == alice || g.winner == bob, "only non-owner holders win");
        assertEq(zombies.ownerOf(PRIZE), g.winner);
        assertEq(zombies.ownerOf(g.winningTokenId), g.winner);
        assertFalse(raffle.isLockedPrize(PRIZE));
    }

    function test_ownerAndContractHoldingsAreSkipped() public {
        uint256 id = _start(1);
        vm.warp(block.timestamp + 2);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        // a word whose first pick is the owner's Zombie #4 and second pick is the prize itself
        uint256 word;
        while (!(_pick(word, 0, 5) == 4 && _pick(word, 1, 5) == PRIZE)) ++word;
        wrapper.fulfill(req, word);
        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Completed));
        assertGe(g.attempts, 3);
        assertTrue(g.winner != owner && g.winner != address(raffle));
    }

    function test_topUpWhenDepositTooSmall_refundsCallerExcess() public {
        vm.prank(owner);
        uint256 id = raffle.startGiveaway{value: 1 wei}(PRIZE, uint64(block.timestamp + 1), 1);
        vm.warp(block.timestamp + 2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffleV3.FeeTooLow.selector, wrapper.PRICE(), 1));
        raffle.draw(id);
        uint256 before = stranger.balance;
        vm.prank(stranger);
        raffle.draw{value: 0.01 ether}(id);
        assertEq(before - stranger.balance, wrapper.PRICE() - 1, "caller pays only the shortfall");
    }

    function test_cancelRulesAndAbandon() public {
        uint256 id = _start(1 days);
        vm.prank(stranger);
        vm.expectRevert();
        raffle.cancel(id);
        uint256 before = owner.balance;
        vm.prank(owner);
        raffle.cancel(id);
        assertEq(zombies.ownerOf(PRIZE), owner);
        assertEq(owner.balance - before, DEPOSIT, "deposit returned");
        assertEq(raffle.lockedFees(), 0);

        // second giveaway: drawn but Chainlink never answers
        uint256 id2 = _start(1);
        vm.warp(block.timestamp + 2);
        vm.prank(stranger);
        uint256 req = raffle.draw(id2);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(GraveyardRaffleV3.WrongStatus.selector, GraveyardRaffleV3.Status.Drawing)
        );
        raffle.cancel(id2);
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        raffle.cancel(id2);
        assertEq(zombies.ownerOf(PRIZE), owner);
        wrapper.fulfill(req, 1); // late answer changes nothing
        assertEq(uint8(raffle.getGiveaway(id2).status), uint8(GraveyardRaffleV3.Status.Cancelled));
    }

    function test_startGuards() public {
        vm.prank(stranger);
        vm.expectRevert();
        raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp + 1), 1);
        vm.startPrank(owner);
        vm.expectRevert(GraveyardRaffleV3.BadCloseTime.selector);
        raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp), 1);
        vm.expectRevert(GraveyardRaffleV3.NoDeposit.selector);
        raffle.startGiveaway(PRIZE, uint64(block.timestamp + 1), 1);
        vm.expectRevert(GraveyardRaffleV3.NotPrizeOwner.selector);
        raffle.startGiveaway{value: DEPOSIT}(1, uint64(block.timestamp + 1), 1);
        vm.stopPrank();
    }

    function test_continuePayoutWhenCallbackBudgetRunsOut() public {
        // owner holds almost everything: find a word where every in-callback pick hits owner/contract tokens
        for (uint256 i = 100; i < 140; ++i) {
            zombies.mint(owner, i);
        }
        uint256 id = _start(1);
        vm.warp(block.timestamp + 2);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        uint256 n = raffle.getGiveaway(id).ticketCount;
        uint256 word;
        for (;; ++word) {
            bool allSkipped = true;
            for (uint32 a; a < raffle.CALLBACK_ATTEMPTS(); ++a) {
                address h = zombies.ownerOf(_pick(word, a, n));
                if (h != owner && h != address(raffle)) {
                    allSkipped = false;
                    break;
                }
            }
            if (allSkipped) break;
        }
        wrapper.fulfill(req, word);
        assertEq(uint8(raffle.getGiveaway(id).status), uint8(GraveyardRaffleV3.Status.Drawn));
        while (raffle.getGiveaway(id).status == GraveyardRaffleV3.Status.Drawn) raffle.continuePayout(id);
        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Completed));
        assertTrue(g.winner == alice || g.winner == bob);
    }

    function test_failedTransferIsRetried() public {
        uint256 id = _start(1);
        vm.warp(block.timestamp + 2);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        zombies.setBlockTransfers(true);
        wrapper.fulfill(req, 42); // callback must not revert
        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Drawn));
        address picked = g.winner;
        assertTrue(picked != address(0));
        zombies.setBlockTransfers(false);
        raffle.continuePayout(id);
        assertEq(zombies.ownerOf(PRIZE), picked, "same winner, paid later");
    }

    function test_ownerCannotBlockDrawByRefusingRefund() public {
        RejectingOwnerV3 ro = new RejectingOwnerV3();
        GraveyardRaffleV3 r = ro.deploy(address(wrapper), address(zombies));
        vm.prank(owner);
        zombies.transferFrom(owner, address(ro), PRIZE);
        vm.deal(address(this), 1 ether);
        ro.approveAndStart{value: DEPOSIT}(r, zombies, PRIZE, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 2);
        vm.prank(stranger);
        r.draw(0); // succeeds; the refund stays in the contract
        assertEq(address(r).balance, DEPOSIT - wrapper.PRICE());
    }

    function test_automationDrawsRightAfterClose() public {
        uint256 id = _start(1 hours);
        (bool needed,) = raffle.checkUpkeep("");
        assertFalse(needed, "nothing to do while open");

        vm.warp(block.timestamp + 1 hours);
        bytes memory data;
        (needed, data) = raffle.checkUpkeep("");
        assertTrue(needed);
        assertEq(abi.decode(data, (uint256)), id);

        address keeper = makeAddr("chainlink automation forwarder");
        uint256 ownerBefore = owner.balance;
        vm.prank(keeper);
        raffle.performUpkeep(data);
        assertEq(uint8(raffle.getGiveaway(id).status), uint8(GraveyardRaffleV3.Status.Drawing));
        assertEq(owner.balance - ownerBefore, DEPOSIT - wrapper.PRICE(), "unused deposit refunded");
        assertEq(keeper.balance, 0, "keeper pays nothing from the raffle");

        (needed,) = raffle.checkUpkeep("");
        assertFalse(needed, "never drawn twice");
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(GraveyardRaffleV3.WrongStatus.selector, GraveyardRaffleV3.Status.Drawing)
        );
        raffle.performUpkeep(data);

        wrapper.fulfill(raffle.getGiveaway(id).requestId, 9);
        assertEq(uint8(raffle.getGiveaway(id).status), uint8(GraveyardRaffleV3.Status.Completed));
    }

    function test_automationHandlesSeveralGiveawaysAndSmallDeposits() public {
        zombies.mint(owner, 2000);
        vm.startPrank(owner);
        uint256 a = raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp + 10), 1);
        uint256 b = raffle.startGiveaway{value: 1 wei}(2000, uint64(block.timestamp + 20), 1); // underfunded
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        (bool needed, bytes memory data) = raffle.checkUpkeep("");
        assertTrue(needed);
        assertEq(abi.decode(data, (uint256)), b, "newest closed first");
        // an underfunded giveaway can't be drawn by automation (the simulation reverts, so it isn't sent)
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffleV3.FeeTooLow.selector, wrapper.PRICE(), 1));
        raffle.performUpkeep(data);
        // anyone can still draw it manually by paying the shortfall
        uint256 price = wrapper.PRICE();
        vm.prank(stranger);
        raffle.draw{value: price}(b);

        (needed, data) = raffle.checkUpkeep("");
        assertTrue(needed);
        assertEq(abi.decode(data, (uint256)), a);
        raffle.performUpkeep(data);
        (needed,) = raffle.checkUpkeep("");
        assertFalse(needed);
    }

    function test_adminGuards() public {
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffleV3.RenounceDisabled.selector);
        raffle.renounceOwnership();

        uint256 id = _start(1 days);
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffleV3.PrizeLocked.selector);
        raffle.rescueToken(address(zombies), PRIZE);

        // withdraw can't touch the locked deposit
        vm.deal(address(raffle), address(raffle).balance + 0.5 ether);
        vm.prank(owner);
        raffle.withdraw(payable(owner));
        assertEq(address(raffle).balance, DEPOSIT);
        id;
    }

    // ------------------------------------------------------------------
    // V3: minimum holding
    // ------------------------------------------------------------------

    function _startMin(uint32 minHolding) internal returns (uint256 id) {
        vm.prank(owner);
        id = raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp + 1), minHolding);
        vm.warp(block.timestamp + 2);
    }

    function test_minHoldingIsStoredAndZeroRejected() public {
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffleV3.BadMinHolding.selector);
        raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp + 1), 0);
        uint256 id = _startMin(2);
        assertEq(raffle.getGiveaway(id).minHolding, 2);
    }

    function test_walletBelowMinimumIsSkipped() public {
        // alice holds #1 and #2, bob holds only #3: with a minimum of 2 only alice can win
        uint256 id = _startMin(2);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        uint256 word;
        while (_pick(word, 0, 5) != 3) ++word; // the first pick lands on bob's Zombie
        wrapper.fulfill(req, word);
        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Completed));
        assertEq(g.winner, alice, "bob holds 1 Zombie, below the minimum");
        assertGe(g.attempts, 2);
    }

    function test_minimumNeverPicksSingleHolder() public {
        // many words: bob (1 Zombie) must never win with a minimum of 2
        for (uint256 w = 1; w <= 40; ++w) {
            vm.prank(owner);
            uint256 id = raffle.startGiveaway{value: DEPOSIT}(PRIZE, uint64(block.timestamp + 1), 2);
            vm.warp(block.timestamp + 2);
            vm.prank(stranger);
            uint256 req = raffle.draw(id);
            wrapper.fulfill(req, uint256(keccak256(abi.encode("w", w))));
            GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
            assertEq(g.winner, alice);
            // give the prize back to the owner for the next round
            vm.prank(alice);
            zombies.transferFrom(alice, owner, PRIZE);
        }
    }

    function test_holdingIsCheckedAtTheDraw() public {
        // bob buys a second Zombie before the draw and becomes eligible
        uint256 id = _startMin(2);
        zombies.mint(bob, 5);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        uint256 word;
        while (_pick(word, 0, 6) != 3) ++word;
        wrapper.fulfill(req, word);
        assertEq(raffle.getGiveaway(id).winner, bob);
    }

    function test_minimumOfOneIsEveryHolder() public {
        uint256 id = _startMin(1);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        uint256 word;
        while (_pick(word, 0, 5) != 3) ++word;
        wrapper.fulfill(req, word);
        assertEq(raffle.getGiveaway(id).winner, bob, "bob's single Zombie counts");
        assertEq(raffle.getGiveaway(id).attempts, 1);
    }

    function test_unreachableMinimumFallsBackToAnyHolder() public {
        // nobody holds 50 Zombies: after MIN_HOLDING_ATTEMPTS picks, any holder can win
        uint256 id = _startMin(50);
        vm.prank(stranger);
        uint256 req = raffle.draw(id);
        wrapper.fulfill(req, 123);
        assertEq(uint8(raffle.getGiveaway(id).status), uint8(GraveyardRaffleV3.Status.Drawn));
        uint256 calls;
        while (raffle.getGiveaway(id).status == GraveyardRaffleV3.Status.Drawn) {
            raffle.continuePayout(id);
            ++calls;
        }
        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Completed));
        assertTrue(g.winner == alice || g.winner == bob);
        assertGt(g.attempts, raffle.MIN_HOLDING_ATTEMPTS(), "minimum applied for the first 512 picks");
        assertLe(calls, 9);
        assertEq(zombies.ownerOf(PRIZE), g.winner);
    }
}

interface IZombiesOnBaseV3 is IERC721Enumerable {
    function owner() external view returns (address);
}

/// Real contracts on a Base mainnet fork: Zombies On Base + Chainlink VRF v2.5 wrapper.
contract GraveyardRaffleV3ForkTest is Test {
    IZombiesOnBaseV3 constant ZOMBIES = IZombiesOnBaseV3(0xa2D33352e3e2B4FE1B8af7387c375828197bcd9B);
    address constant WRAPPER = 0xb0407dbe851f8318bd31404A49e658143C982F23;
    address constant OWNER = 0x9C977b3A786B05823620756C4B9F3435E1f05acf;

    function test_fork_twoPressGiveaway() public {
        vm.createSelectFork("base");
        vm.prank(OWNER);
        GraveyardRaffleV3 raffle = new GraveyardRaffleV3(WRAPPER, address(ZOMBIES));
        uint256 prize = ZOMBIES.tokenOfOwnerByIndex(OWNER, 0);

        vm.startPrank(OWNER);
        ZOMBIES.setApprovalForAll(address(raffle), true);
        raffle.startGiveaway{value: 0.0005 ether}(prize, uint64(block.timestamp + 1 hours), 2);
        vm.stopPrank();
        assertEq(ZOMBIES.ownerOf(prize), address(raffle));

        vm.warp(block.timestamp + 1 hours);
        vm.txGasPrice(0.012 gwei);
        emit log_named_uint("VRF fee (wei) at 0.012 gwei", raffle.drawPrice());
        (bool needed, bytes memory performData) = raffle.checkUpkeep("");
        assertTrue(needed, "Automation sees the closed giveaway");
        vm.prank(makeAddr("automation forwarder"));
        raffle.performUpkeep(performData);
        uint256 req = raffle.getGiveaway(0).requestId;

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("graveyard v3"));
        uint32 limit = raffle.CALLBACK_GAS_LIMIT();
        vm.prank(WRAPPER);
        uint256 g0 = gasleft();
        raffle.rawFulfillRandomWords{gas: limit}(req, words);
        emit log_named_uint("callback gas used", g0 - gasleft());

        GraveyardRaffleV3.Giveaway memory g = raffle.getGiveaway(0);
        assertEq(uint8(g.status), uint8(GraveyardRaffleV3.Status.Completed), "paid inside the callback gas limit");
        assertEq(ZOMBIES.ownerOf(prize), g.winner);
        assertTrue(g.winner != OWNER);
        emit log_named_address("winner", g.winner);
        emit log_named_uint("attempts", g.attempts);
        assertGe(ZOMBIES.balanceOf(g.winner), 2, "winner meets the minimum of 2");
    }

    /// Worst case for the callback: no wallet meets the minimum, so every in-callback pick is skipped.
    function test_fork_callbackGasWhenEveryPickIsSkipped() public {
        vm.createSelectFork("base");
        vm.prank(OWNER);
        GraveyardRaffleV3 raffle = new GraveyardRaffleV3(WRAPPER, address(ZOMBIES));
        uint256 prize = ZOMBIES.tokenOfOwnerByIndex(OWNER, 0);
        vm.startPrank(OWNER);
        ZOMBIES.setApprovalForAll(address(raffle), true);
        raffle.startGiveaway{value: 0.0005 ether}(prize, uint64(block.timestamp + 1 hours), 100_000);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        vm.txGasPrice(0.012 gwei);
        raffle.draw(0);

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("graveyard v3 worst case"));
        uint32 limit = raffle.CALLBACK_GAS_LIMIT();
        uint256 req = raffle.getGiveaway(0).requestId;
        vm.prank(WRAPPER);
        uint256 g0 = gasleft();
        raffle.rawFulfillRandomWords{gas: limit}(req, words);
        uint256 skippedGas = g0 - gasleft();
        emit log_named_uint("callback gas, all picks skipped", skippedGas);
        // worst case: every pick but the last skipped, then the payout (~123k measured above it)
        assertLt(skippedGas + 140_000, limit, "worst case fits the callback gas limit");
        assertEq(uint8(raffle.getGiveaway(0).status), uint8(GraveyardRaffleV3.Status.Drawn));
        assertEq(raffle.getGiveaway(0).attempts, raffle.CALLBACK_ATTEMPTS());

        // continuePayout batches stay well under a block, and the fallback finishes the payout
        uint256 calls;
        while (raffle.getGiveaway(0).status == GraveyardRaffleV3.Status.Drawn) {
            uint256 c0 = gasleft();
            raffle.continuePayout(0);
            if (calls++ == 0) emit log_named_uint("continuePayout gas (64 picks)", c0 - gasleft());
        }
        assertEq(ZOMBIES.ownerOf(prize), raffle.getGiveaway(0).winner);
        emit log_named_uint("continuePayout calls until paid", calls);
    }
}
