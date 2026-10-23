// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GraveyardRaffle} from "../src/GraveyardRaffle.sol";

contract MockZombies is ERC721("Zombies On Base", "ZOB") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// Minimal stand-in for Chainlink's VRFV2PlusWrapper (direct funding, native payment).
contract MockVRFWrapper {
    uint256 public constant PRICE = 0.0001 ether;
    uint256 public lastRequestId;
    mapping(uint256 => address) public consumerOf;

    function link() external pure returns (address) {
        return address(0xBEEF);
    }

    function calculateRequestPriceNative(uint32, uint32) external pure returns (uint256) {
        return PRICE;
    }

    function requestRandomWordsInNative(uint32, uint16, uint32, bytes calldata) external payable returns (uint256) {
        require(msg.value == PRICE, "fee");
        lastRequestId += 1;
        consumerOf[lastRequestId] = msg.sender;
        return lastRequestId;
    }

    function fulfill(uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        GraveyardRaffle(payable(consumerOf[requestId])).rawFulfillRandomWords(requestId, words);
    }
}

/// Builds Merkle trees the same way OpenZeppelin's StandardMerkleTree verifies them:
/// leaf = keccak256(bytes.concat(keccak256(abi.encode(index, holder, tokenId)))), sorted pairs.
abstract contract MerkleHelper {
    function _leaf(uint256 index, address holder, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, holder, tokenId))));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _root(bytes32[] memory level) internal pure returns (bytes32) {
        while (level.length > 1) level = _up(level);
        return level[0];
    }

    function _proof(bytes32[] memory level, uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory tmp = new bytes32[](32);
        uint256 n;
        while (level.length > 1) {
            uint256 sib = index ^ 1;
            if (sib < level.length) tmp[n++] = level[sib];
            level = _up(level);
            index /= 2;
        }
        proof = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            proof[i] = tmp[i];
        }
    }

    function _up(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < level.length; i += 2) {
            next[i / 2] = i + 1 < level.length ? _pair(level[i], level[i + 1]) : level[i];
        }
    }
}

contract GraveyardRaffleTest is Test, MerkleHelper {
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    MockZombies zombies;
    MockVRFWrapper wrapper;
    GraveyardRaffle raffle;

    uint256 constant PRIZE = 1118;
    address[] holders;
    uint256[] tickets;
    bytes32[] leaves;

    function setUp() public {
        zombies = new MockZombies();
        wrapper = new MockVRFWrapper();
        vm.prank(owner);
        raffle = new GraveyardRaffle(address(wrapper), address(zombies));

        zombies.mint(owner, PRIZE);
        // tickets: alice 1,2,3 · bob 4 · carol 5
        _ticket(alice, 1);
        _ticket(alice, 2);
        _ticket(alice, 3);
        _ticket(bob, 4);
        _ticket(carol, 5);
        vm.deal(stranger, 1 ether);
    }

    function _ticket(address h, uint256 tokenId) internal {
        zombies.mint(h, tokenId);
        leaves.push(_leaf(holders.length, h, tokenId));
        holders.push(h);
        tickets.push(tokenId);
    }

    function _open(uint64 closesAt) internal returns (uint256 id) {
        id = raffle.giveawayCount();
        vm.prank(owner);
        zombies.safeTransferFrom(owner, address(raffle), PRIZE, abi.encode(closesAt));
    }

    function _openCommitDraw(uint256 word) internal returns (uint256 id) {
        id = _open(uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        raffle.commitEntrants(id, _root(leaves), uint32(leaves.length), "snapshots/giveaway-0.json");
        vm.prank(stranger);
        uint256 req = raffle.requestDraw{value: 0.001 ether}(id);
        wrapper.fulfill(req, word);
    }

    function _settleDrawn(uint256 id) internal returns (bool) {
        uint32 i = raffle.drawnIndex(id);
        return raffle.settle(id, i, holders[i], tickets[i], _proof(leaves, i));
    }

    function test_fullFlow() public {
        uint256 id = _open(uint64(block.timestamp + 1 days));
        assertEq(zombies.ownerOf(PRIZE), address(raffle));
        assertEq(uint8(raffle.getGiveaway(id).status), uint8(GraveyardRaffle.Status.Open));

        bytes32 root = _root(leaves);
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffle.StillOpen.selector);
        raffle.commitEntrants(id, root, 5, "x");

        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable_Unauthorized(), stranger));
        raffle.commitEntrants(id, root, 5, "x");

        vm.prank(owner);
        raffle.commitEntrants(id, root, 5, "snapshots/giveaway-0.json");

        uint256 before = stranger.balance;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.FeeTooLow.selector, wrapper.PRICE()));
        raffle.requestDraw{value: 1}(id);
        vm.prank(stranger);
        uint256 req = raffle.requestDraw{value: 0.001 ether}(id);
        assertEq(before - stranger.balance, wrapper.PRICE(), "excess fee refunded");

        vm.expectRevert(); // only the wrapper may fulfill
        raffle.rawFulfillRandomWords(req, new uint256[](1));

        wrapper.fulfill(req, 123456789);
        uint32 i = raffle.drawnIndex(id);

        bytes32[] memory proof = _proof(leaves, i);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.WrongIndex.selector, i));
        raffle.settle(id, (i + 1) % 5, holders[i], tickets[i], proof);
        vm.expectRevert(GraveyardRaffle.InvalidProof.selector);
        raffle.settle(id, i, stranger, tickets[i], proof);

        assertTrue(raffle.settle(id, i, holders[i], tickets[i], proof));
        assertEq(zombies.ownerOf(PRIZE), holders[i]);
        GraveyardRaffle.Giveaway memory g = raffle.getGiveaway(id);
        assertEq(uint8(g.status), uint8(GraveyardRaffle.Status.Completed));
        assertEq(g.winner, holders[i]);
        assertEq(g.winningTokenId, tickets[i]);
        assertEq(g.randomWord, 123456789);
        assertEq(g.entrantsURI, "snapshots/giveaway-0.json");
    }

    function test_soldTicketIsVoidedAndRedrawn() public {
        uint256 id = _openCommitDraw(42);
        uint32 first = raffle.drawnIndex(id);
        // the drawn holder sells their Zombie after the snapshot
        vm.prank(holders[first]);
        zombies.transferFrom(holders[first], stranger, tickets[first]);

        assertFalse(_settleDrawn(id));
        assertEq(raffle.getGiveaway(id).rerolls, 1);

        // keep settling until someone who still holds wins
        bool paid;
        for (uint256 k; k < 20 && !paid; ++k) {
            uint32 i = raffle.drawnIndex(id);
            if (i == first) {
                assertFalse(raffle.settle(id, i, holders[i], tickets[i], _proof(leaves, i)));
            } else {
                paid = _settleDrawn(id);
            }
        }
        assertTrue(paid);
        assertTrue(zombies.ownerOf(PRIZE) != stranger);
    }

    function test_onlyOwnerCanOpen_andOnlyZombies() public {
        zombies.mint(stranger, 999);
        vm.prank(stranger);
        vm.expectRevert(GraveyardRaffle.PrizeNotFromOwner.selector);
        zombies.safeTransferFrom(stranger, address(raffle), 999, abi.encode(uint64(block.timestamp + 1 days)));

        MockZombies other = new MockZombies();
        other.mint(owner, 1);
        vm.prank(owner);
        vm.expectRevert(GraveyardRaffle.WrongCollection.selector);
        other.safeTransferFrom(owner, address(raffle), 1, abi.encode(uint64(block.timestamp + 1 days)));

        vm.prank(owner);
        vm.expectRevert(GraveyardRaffle.BadCloseTime.selector);
        zombies.safeTransferFrom(owner, address(raffle), PRIZE, abi.encode(uint64(block.timestamp)));
    }

    function test_cancelRules() public {
        uint256 id = _open(uint64(block.timestamp + 1 days));
        vm.prank(stranger);
        vm.expectRevert();
        raffle.cancel(id);
        vm.prank(owner);
        raffle.cancel(id);
        assertEq(zombies.ownerOf(PRIZE), owner);

        // once drawn, the owner can never pull the prize back
        uint256 id2 = _openCommitDraw(7);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.WrongStatus.selector, GraveyardRaffle.Status.Drawn));
        raffle.cancel(id2);
    }

    function test_vrfRetryIgnoresStaleAnswer_andAbandon() public {
        uint256 id = _open(uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        raffle.commitEntrants(id, _root(leaves), 5, "x");
        vm.prank(stranger);
        uint256 req1 = raffle.requestDraw{value: 0.0001 ether}(id);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.WrongStatus.selector, GraveyardRaffle.Status.Drawing));
        raffle.requestDraw{value: 0.0001 ether}(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GraveyardRaffle.WrongStatus.selector, GraveyardRaffle.Status.Drawing));
        raffle.cancel(id);

        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        uint256 req2 = raffle.requestDraw{value: 0.0001 ether}(id);

        wrapper.fulfill(req1, 1); // stale: ignored
        assertEq(uint8(raffle.getGiveaway(id).status), uint8(GraveyardRaffle.Status.Drawing));
        wrapper.fulfill(req2, 2);
        assertEq(raffle.getGiveaway(id).randomWord, 2);

        // separate giveaway where Chainlink never answers: owner may recover after 7 days
        zombies.mint(owner, 2000);
        vm.prank(owner);
        zombies.safeTransferFrom(owner, address(raffle), 2000, abi.encode(uint64(block.timestamp + 1)));
        vm.warp(block.timestamp + 2);
        vm.prank(owner);
        raffle.commitEntrants(1, _root(leaves), 5, "x");
        vm.prank(stranger);
        raffle.requestDraw{value: 0.0001 ether}(1);
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        raffle.cancel(1);
        assertEq(zombies.ownerOf(2000), owner);
    }

    function Ownable_Unauthorized() internal pure returns (bytes4) {
        return bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
    }
}

interface IZombiesOnBase is IERC721 {
    function owner() external view returns (address);
    function tokenByIndex(uint256 index) external view returns (uint256);
}

/// Real contracts on a Base mainnet fork: Zombies On Base + Chainlink VRF v2.5 wrapper.
contract GraveyardRaffleForkTest is Test, MerkleHelper {
    IZombiesOnBase constant ZOMBIES = IZombiesOnBase(0xa2D33352e3e2B4FE1B8af7387c375828197bcd9B);
    address constant WRAPPER = 0xb0407dbe851f8318bd31404A49e658143C982F23;
    address constant OWNER = 0x9C977b3A786B05823620756C4B9F3435E1f05acf;

    function test_fork_giveaway1118() public {
        vm.createSelectFork("base");
        vm.prank(OWNER);
        GraveyardRaffle raffle = new GraveyardRaffle(WRAPPER, address(ZOMBIES));

        vm.prank(OWNER);
        ZOMBIES.safeTransferFrom(OWNER, address(raffle), 1118, abi.encode(uint64(block.timestamp + 1 days)));
        assertEq(ZOMBIES.ownerOf(1118), address(raffle));

        // tickets from the real holders of the first 8 minted Zombies
        uint256 n = 8;
        bytes32[] memory leaves = new bytes32[](n);
        address[] memory hs = new address[](n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = ZOMBIES.tokenByIndex(i);
            hs[i] = ZOMBIES.ownerOf(ids[i]);
            leaves[i] = _leaf(i, hs[i], ids[i]);
        }
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        raffle.commitEntrants(0, _root(leaves), uint32(n), "snapshots/giveaway-0.json");

        vm.txGasPrice(0.01 gwei);
        uint256 price = raffle.drawPrice();
        emit log_named_uint("VRF fee (wei) at 0.01 gwei", price);
        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        uint256 req = raffle.requestDraw{value: price * 2}(0);
        assertEq(caller.balance, 1 ether - price, "refund");

        // Chainlink's wrapper delivers the randomness
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("zombie szn"));
        vm.prank(WRAPPER);
        raffle.rawFulfillRandomWords(req, words);

        uint32 idx = raffle.drawnIndex(0);
        assertTrue(raffle.settle(0, idx, hs[idx], ids[idx], _proof(leaves, idx)));
        assertEq(ZOMBIES.ownerOf(1118), hs[idx]);
        emit log_named_address("winner", hs[idx]);
    }
}
