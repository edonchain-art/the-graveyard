// SPDX-License-Identifier: MIT
//
//   _____ _            _____                                         _
//  |_   _| |          |  __ \                                       | |
//    | | | |__   ___  | |  \/_ __ __ ___   _____ _   _  __ _ _ __ __| |
//    | | | '_ \ / _ \ | | __| '__/ _` \ \ / / _ \ | | |/ _` | '__/ _` |
//    | | | | | |  __/ | |_\ \ | | (_| |\ V /  __/ |_| | (_| | | | (_| |
//    \_/ |_| |_|\___|  \____/_|  \__,_| \_/ \___|\__, |\__,_|_|  \__,_|
//                                                 __/ |
//                                                |___/
//
//                                                         by: EdOnChain
//
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
///   4. Drawn      Chainlink delivers the random word. The winning ticket is fixed:
///                 keccak256(abi.encode(randomWord)) % entrantCount.
///   5. Completed  Anyone calls settle() with the winning ticket and its Merkle proof, and
///                 the prize is sent to the holder recorded in the snapshot. Nothing that
///                 happens after the snapshot can change who wins.
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
    /// @notice After this long without a VRF response, the owner may cancel and recover the prize.
    ///         Randomness is never re-requested for a giveaway (Chainlink's guidance).
    uint64 public constant VRF_ABANDON_AFTER = 7 days;

    IERC721 public immutable zombies;

    Giveaway[] internal _giveaways;
    /// @dev requestId => giveaway id + 1 (0 means unknown request)
    mapping(uint256 => uint256) internal _giveawayOfRequest;
    /// @dev Zombies currently held as the prize of an unfinished giveaway.
    mapping(uint256 => bool) public isLockedPrize;

    event GiveawayOpened(uint256 indexed id, uint256 indexed prizeTokenId, uint64 closesAt);
    event EntrantsCommitted(uint256 indexed id, bytes32 root, uint32 entrantCount, string entrantsURI);
    event DrawRequested(uint256 indexed id, uint256 indexed requestId, uint256 price);
    event RandomnessReceived(uint256 indexed id, uint256 indexed requestId, uint256 randomWord);
    event WinnerPaid(
        uint256 indexed id, address indexed winner, uint256 prizeTokenId, uint256 winningTokenId, uint32 index
    );
    event GiveawayCancelled(uint256 indexed id);
    event TokenRescued(address indexed token, uint256 indexed tokenId, address to);

    error WrongCollection();
    error PrizeNotFromOwner();
    error BadCloseTime();
    error UnknownGiveaway();
    error WrongStatus(Status status);
    error StillOpen();
    error NoEntrants();
    error FeeTooLow(uint256 required);
    error WrongIndex(uint32 expected);
    error InvalidProof();
    error RefundFailed();
    error RenounceDisabled();
    error PrizeLocked();

    constructor(address vrfWrapper, address zombies_) VRFV2PlusWrapperConsumerBase(vrfWrapper) Ownable(msg.sender) {
        zombies = IERC721(zombies_);
    }

    // ------------------------------------------------------------------
    // 1. Open: receive the prize
    // ------------------------------------------------------------------

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external returns (bytes4) {
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
        isLockedPrize[tokenId] = true;
        emit GiveawayOpened(id, tokenId, closesAt);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------
    // 2. Committed: publish the snapshot
    // ------------------------------------------------------------------

    /// @notice Commit (or, until a draw is requested, re-commit) the eligible ticket list.
    /// @dev entrantCount must equal the number of leaves under root. The contract cannot check
    ///      this; the snapshot tooling and the site verify it before committing.
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

    /// @notice Request the random word. Can only happen once per giveaway.
    function requestDraw(uint256 id) external payable returns (uint256 requestId) {
        Giveaway storage g = _get(id);
        if (g.status != Status.Committed) revert WrongStatus(g.status);

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
        if (g.status != Status.Drawing || g.requestId != requestId) return;
        g.randomWord = randomWords[0];
        g.status = Status.Drawn;
        emit RandomnessReceived(ref - 1, requestId, randomWords[0]);
    }

    // ------------------------------------------------------------------
    // 5. Completed: settle with the winning ticket (anyone)
    // ------------------------------------------------------------------

    /// @notice Index of the winning ticket. Fixed as soon as the random word arrives.
    function drawnIndex(uint256 id) public view returns (uint32) {
        Giveaway storage g = _get(id);
        if (g.status != Status.Drawn) revert WrongStatus(g.status);
        return uint32(uint256(keccak256(abi.encode(g.randomWord))) % g.entrantCount);
    }

    /// @notice Send the prize to the holder of the winning ticket, as recorded in the snapshot.
    function settle(uint256 id, uint32 index, address holder, uint256 zombieTokenId, bytes32[] calldata proof)
        external
    {
        Giveaway storage g = _get(id);
        uint32 expected = drawnIndex(id);
        if (index != expected) revert WrongIndex(expected);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(index), holder, zombieTokenId))));
        if (!MerkleProof.verifyCalldata(proof, g.entrantsRoot, leaf)) revert InvalidProof();

        g.winner = holder;
        g.winningTokenId = zombieTokenId;
        g.winningIndex = index;
        g.completedAt = uint64(block.timestamp);
        g.status = Status.Completed;
        isLockedPrize[g.prizeTokenId] = false;
        emit WinnerPaid(id, holder, g.prizeTokenId, zombieTokenId, index);
        zombies.transferFrom(address(this), holder, g.prizeTokenId);
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
        isLockedPrize[g.prizeTokenId] = false;
        emit GiveawayCancelled(id);
        zombies.transferFrom(address(this), owner(), g.prizeTokenId);
    }

    /// @notice Return an NFT sent here by mistake (for example with a plain transferFrom).
    ///         The prize of an unfinished giveaway can never be rescued.
    function rescueToken(address token, uint256 tokenId) external onlyOwner {
        if (token == address(zombies) && isLockedPrize[tokenId]) revert PrizeLocked();
        emit TokenRescued(token, tokenId, owner());
        IERC721(token).transferFrom(address(this), owner(), tokenId);
    }

    function withdraw(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        if (!ok) revert RefundFailed();
    }

    /// @notice Disabled: without an owner, open giveaways could never be committed or cancelled.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
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

    receive() external payable {}
}
