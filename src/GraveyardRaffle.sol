// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title  GraveyardRaffle
/// @notice Onchain giveaways of Zombies On Base tokens to Zombies holders, drawn with
///         Chainlink VRF v2.5 (direct funding, paid in ETH).
///
/// Lifecycle of a giveaway:
///   1. Open       The owner sends the prize Zombie to this contract with
///                 safeTransferFrom(owner, raffle, tokenId, abi.encode(uint64 closesAt)).
///                 From here the prize can only go to a winner, or back to the owner if
///                 the giveaway is cancelled before a draw is requested.
///   2. Committed  After closesAt, the owner commits the snapshot: a Merkle root over
///                 (index, holder, zombieTokenId) tickets, the ticket count and a URI where
///                 the full list is published. One ticket per eligible Zombie.
///   3. Drawing    Anyone calls requestDraw() and pays the Chainlink VRF fee.
///   4. Drawn      Chainlink delivers the random word.
///   5. Completed  Anyone calls settle() with the drawn ticket and its Merkle proof. If the
///                 holder still owns that Zombie, the prize is sent to them; otherwise the
///                 ticket is void and the draw moves to the next index derived from the
///                 same random word.
contract GraveyardRaffle is VRFV2PlusWrapperConsumerBase, Ownable2Step, IERC721Receiver {
    enum Status {
        None,
        Open,
        Committed,
        Drawing,
        Drawn,
        Completed,
        Cancelled
    }

    struct Giveaway {
        uint256 prizeTokenId;
        uint64 openedAt;
        uint64 closesAt;
        uint64 requestedAt;
        uint64 completedAt;
        Status status;
        uint32 entrantCount;
        uint32 rerolls;
        bytes32 entrantsRoot;
        string entrantsURI;
        uint256 requestId;
        uint256 randomWord;
        address winner;
        uint256 winningTokenId;
        uint32 winningIndex;
    }

    uint32 public constant CALLBACK_GAS_LIMIT = 100_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    /// @notice After this long without a VRF response, a new draw can be requested.
    uint64 public constant VRF_RETRY_AFTER = 1 days;
    /// @notice After this long without a VRF response, the owner may cancel and recover the prize.
    uint64 public constant VRF_ABANDON_AFTER = 7 days;

    IERC721 public immutable zombies;

    Giveaway[] internal _giveaways;
    /// @dev requestId => giveaway id + 1 (0 means unknown request)
    mapping(uint256 => uint256) internal _giveawayOfRequest;

    event GiveawayOpened(uint256 indexed id, uint256 indexed prizeTokenId, uint64 closesAt);
    event EntrantsCommitted(uint256 indexed id, bytes32 root, uint32 entrantCount, string entrantsURI);
    event DrawRequested(uint256 indexed id, uint256 indexed requestId, uint256 price);
    event RandomnessReceived(uint256 indexed id, uint256 indexed requestId, uint256 randomWord);
    event TicketVoided(uint256 indexed id, uint32 index, address holder, uint256 zombieTokenId);
    event WinnerPaid(uint256 indexed id, address indexed winner, uint256 prizeTokenId, uint256 winningTokenId, uint32 index);
    event GiveawayCancelled(uint256 indexed id);

    error WrongCollection();
    error PrizeNotFromOwner();
    error BadCloseTime();
    error UnknownGiveaway();
    error WrongStatus(Status status);
    error StillOpen();
    error NoEntrants();
    error NotYet();
    error FeeTooLow(uint256 required);
    error WrongIndex(uint32 expected);
    error InvalidProof();
    error RefundFailed();

    constructor(address vrfWrapper, address zombies_)
        VRFV2PlusWrapperConsumerBase(vrfWrapper)
        Ownable(msg.sender)
    {
        zombies = IERC721(zombies_);
    }

    // ------------------------------------------------------------------
    // 1. Open: receive the prize
    // ------------------------------------------------------------------

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        if (msg.sender != address(zombies)) revert WrongCollection();
        if (from != owner()) revert PrizeNotFromOwner();
        uint64 closesAt = abi.decode(data, (uint64));
        if (closesAt <= block.timestamp) revert BadCloseTime();

        uint256 id = _giveaways.length;
        Giveaway storage g = _giveaways.push();
        g.prizeTokenId = tokenId;
        g.openedAt = uint64(block.timestamp);
        g.closesAt = closesAt;
        g.status = Status.Open;
        emit GiveawayOpened(id, tokenId, closesAt);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------
    // 2. Committed: publish the snapshot
    // ------------------------------------------------------------------

    /// @notice Commit (or, until a draw is requested, re-commit) the eligible ticket list.
    function commitEntrants(uint256 id, bytes32 root, uint32 entrantCount, string calldata entrantsURI)
        external
        onlyOwner
    {
        Giveaway storage g = _get(id);
        if (g.status != Status.Open && g.status != Status.Committed) revert WrongStatus(g.status);
        if (block.timestamp < g.closesAt) revert StillOpen();
        if (entrantCount == 0 || root == bytes32(0)) revert NoEntrants();
        g.entrantsRoot = root;
        g.entrantCount = entrantCount;
        g.entrantsURI = entrantsURI;
        g.status = Status.Committed;
        emit EntrantsCommitted(id, root, entrantCount, entrantsURI);
    }

    // ------------------------------------------------------------------
    // 3. Drawing: ask Chainlink VRF for randomness (anyone, pays the fee)
    // ------------------------------------------------------------------

    /// @notice Current VRF fee in wei. Depends on the gas price of the calling transaction.
    function drawPrice() public view returns (uint256) {
        return i_vrfV2PlusWrapper.calculateRequestPriceNative(CALLBACK_GAS_LIMIT, 1);
    }

    function requestDraw(uint256 id) external payable returns (uint256 requestId) {
        Giveaway storage g = _get(id);
        bool retry = g.status == Status.Drawing && block.timestamp >= g.requestedAt + VRF_RETRY_AFTER;
        if (g.status != Status.Committed && !retry) revert WrongStatus(g.status);

        uint256 price = drawPrice();
        if (msg.value < price) revert FeeTooLow(price);

        (requestId,) = requestRandomnessPayInNative(
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            1,
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
        );
        g.requestId = requestId;
        g.requestedAt = uint64(block.timestamp);
        g.status = Status.Drawing;
        _giveawayOfRequest[requestId] = id + 1;
        emit DrawRequested(id, requestId, price);

        if (msg.value > price) {
            (bool ok,) = msg.sender.call{value: msg.value - price}("");
            if (!ok) revert RefundFailed();
        }
    }

    // ------------------------------------------------------------------
    // 4. Drawn: Chainlink callback (must never revert)
    // ------------------------------------------------------------------

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 ref = _giveawayOfRequest[requestId];
        if (ref == 0 || randomWords.length == 0) return;
        Giveaway storage g = _giveaways[ref - 1];
        if (g.status != Status.Drawing || g.requestId != requestId) return; // stale retry
        g.randomWord = randomWords[0];
        g.status = Status.Drawn;
        emit RandomnessReceived(ref - 1, requestId, randomWords[0]);
    }

    // ------------------------------------------------------------------
    // 5. Completed: settle with the drawn ticket (anyone)
    // ------------------------------------------------------------------

    /// @notice Index of the ticket currently drawn for a giveaway.
    function drawnIndex(uint256 id) public view returns (uint32) {
        Giveaway storage g = _get(id);
        if (g.status != Status.Drawn) revert WrongStatus(g.status);
        return uint32(uint256(keccak256(abi.encode(g.randomWord, g.rerolls))) % g.entrantCount);
    }

    /// @notice Pay the prize to the drawn ticket's holder, or void the ticket if that holder
    ///         no longer owns the Zombie (the next call then uses the next drawn index).
    /// @return paid True if the prize was sent.
    function settle(uint256 id, uint32 index, address holder, uint256 zombieTokenId, bytes32[] calldata proof)
        external
        returns (bool paid)
    {
        Giveaway storage g = _get(id);
        uint32 expected = drawnIndex(id);
        if (index != expected) revert WrongIndex(expected);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(index), holder, zombieTokenId))));
        if (!MerkleProof.verifyCalldata(proof, g.entrantsRoot, leaf)) revert InvalidProof();

        if (_ownerOf(zombieTokenId) != holder) {
            g.rerolls += 1;
            emit TicketVoided(id, index, holder, zombieTokenId);
            return false;
        }

        g.winner = holder;
        g.winningTokenId = zombieTokenId;
        g.winningIndex = index;
        g.completedAt = uint64(block.timestamp);
        g.status = Status.Completed;
        emit WinnerPaid(id, holder, g.prizeTokenId, zombieTokenId, index);
        zombies.transferFrom(address(this), holder, g.prizeTokenId);
        return true;
    }

    // ------------------------------------------------------------------
    // Owner escape hatches
    // ------------------------------------------------------------------

    /// @notice Cancel before a draw is requested (or if Chainlink never answered for 7 days)
    ///         and return the prize to the owner. A drawn giveaway can never be cancelled.
    function cancel(uint256 id) external onlyOwner {
        Giveaway storage g = _get(id);
        bool abandoned = g.status == Status.Drawing && block.timestamp >= g.requestedAt + VRF_ABANDON_AFTER;
        if (g.status != Status.Open && g.status != Status.Committed && !abandoned) revert WrongStatus(g.status);
        g.status = Status.Cancelled;
        emit GiveawayCancelled(id);
        zombies.transferFrom(address(this), owner(), g.prizeTokenId);
    }

    function withdraw(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        if (!ok) revert RefundFailed();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function giveawayCount() external view returns (uint256) {
        return _giveaways.length;
    }

    function getGiveaway(uint256 id) external view returns (Giveaway memory) {
        return _get(id);
    }

    function _get(uint256 id) internal view returns (Giveaway storage) {
        if (id >= _giveaways.length) revert UnknownGiveaway();
        return _giveaways[id];
    }

    function _ownerOf(uint256 tokenId) internal view returns (address) {
        try zombies.ownerOf(tokenId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    receive() external payable {}
}
