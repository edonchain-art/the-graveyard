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
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/// @title  GraveyardRaffleV2
/// @notice Two-step onchain giveaways of Zombies On Base tokens to Zombies holders, drawn
///         with Chainlink VRF v2.5 (direct funding, paid in ETH). No snapshot file.
///
/// Lifecycle of a giveaway:
///   1. Open       The owner calls startGiveaway(prize, closesAt) with ETH for the Chainlink
///                 fee. The prize Zombie is pulled into this contract (the owner approves
///                 this contract once). It can only go to a winner, or back to the owner if
///                 the giveaway is cancelled before the draw.
///   2. Drawing    After closesAt, Chainlink Automation (performUpkeep) or anyone (draw())
///                 requests the random number. The fee comes from the deposit (a manual
///                 caller can pay a shortfall) and the unused deposit is refunded.
///   3. Completed  Chainlink delivers the random word and, in the same transaction, the
///                 contract picks a random Zombie (index = keccak256(word, attempt) %
///                 supply) and sends the prize to whoever holds it. Zombies held by the
///                 owner or by this contract are skipped and the next attempt is drawn.
///                 Every Zombie in existence is one ticket; its holder at that moment wins.
///   (Drawn)       If no eligible holder was found within the attempt budget, or the
///                 transfer failed, anyone can finish it with continuePayout().
contract GraveyardRaffleV2 is VRFV2PlusWrapperConsumerBase, Ownable2Step, AutomationCompatibleInterface {
    enum Status {
        None,
        Open,
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
        uint32 ticketCount;
        uint32 attempts;
        uint256 feeDeposit;
        uint256 feePaid;
        uint256 requestId;
        uint256 randomWord;
        address winner;
        uint256 winningTokenId;
    }

    /// @notice Gas Chainlink gives the callback: random pick plus the prize transfer.
    uint32 public constant CALLBACK_GAS_LIMIT = 500_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    /// @notice Random picks tried inside the Chainlink callback before handing over to continuePayout().
    uint32 public constant CALLBACK_ATTEMPTS = 8;
    /// @notice Random picks tried per continuePayout() call.
    uint32 public constant CONTINUE_ATTEMPTS = 64;
    /// @notice Newest giveaways scanned by checkUpkeep.
    uint256 public constant UPKEEP_SCAN = 50;
    /// @notice After this long without a VRF response, the owner may cancel and recover the prize.
    ///         Randomness is never re-requested for a giveaway (Chainlink's guidance).
    uint64 public constant VRF_ABANDON_AFTER = 7 days;

    IERC721Enumerable public immutable zombies;

    Giveaway[] internal _giveaways;
    /// @dev requestId => giveaway id + 1 (0 means unknown request)
    mapping(uint256 => uint256) internal _giveawayOfRequest;
    /// @notice Zombies currently held as the prize of an unfinished giveaway.
    mapping(uint256 => bool) public isLockedPrize;
    /// @notice ETH deposited for fees of giveaways that haven't drawn yet (not withdrawable).
    uint256 public lockedFees;

    event GiveawayOpened(uint256 indexed id, uint256 indexed prizeTokenId, uint64 closesAt, uint256 feeDeposit);
    event DrawRequested(uint256 indexed id, uint256 indexed requestId, uint256 price, uint32 ticketCount);
    event RandomnessReceived(uint256 indexed id, uint256 indexed requestId, uint256 randomWord);
    event TicketSkipped(uint256 indexed id, uint32 attempt, uint256 zombieTokenId, address holder);
    event WinnerPaid(uint256 indexed id, address indexed winner, uint256 prizeTokenId, uint256 winningTokenId);
    event PayoutPending(uint256 indexed id, uint32 attempts);
    event GiveawayCancelled(uint256 indexed id);
    event TokenRescued(address indexed token, uint256 indexed tokenId, address to);

    error UnknownGiveaway();
    error WrongStatus(Status status);
    error BadCloseTime();
    error NoDeposit();
    error StillOpen();
    error NoTickets();
    error FeeTooLow(uint256 required, uint256 available);
    error TransferFailed();
    error RenounceDisabled();
    error PrizeLocked();
    error NotPrizeOwner();

    constructor(address vrfWrapper, address zombies_) VRFV2PlusWrapperConsumerBase(vrfWrapper) Ownable(msg.sender) {
        zombies = IERC721Enumerable(zombies_);
    }

    // ------------------------------------------------------------------
    // 1. Open: prize + fee in one transaction
    // ------------------------------------------------------------------

    /// @notice Lock a Zombie as the prize and deposit ETH for the Chainlink fee.
    /// @dev The owner must have approved this contract for the prize (approve or setApprovalForAll).
    function startGiveaway(uint256 prizeTokenId, uint64 closesAt) external payable onlyOwner returns (uint256 id) {
        if (closesAt <= block.timestamp) revert BadCloseTime();
        if (msg.value == 0) revert NoDeposit();
        if (zombies.ownerOf(prizeTokenId) != msg.sender) revert NotPrizeOwner();

        id = _giveaways.length;
        Giveaway storage g = _giveaways.push();
        g.prizeTokenId = prizeTokenId;
        g.openedAt = uint64(block.timestamp);
        g.closesAt = closesAt;
        g.status = Status.Open;
        g.feeDeposit = msg.value;
        lockedFees += msg.value;
        isLockedPrize[prizeTokenId] = true;
        emit GiveawayOpened(id, prizeTokenId, closesAt, msg.value);

        zombies.transferFrom(msg.sender, address(this), prizeTokenId);
    }

    // ------------------------------------------------------------------
    // 2. Drawing: anyone, after the close
    // ------------------------------------------------------------------

    /// @notice Current VRF fee in wei. Depends on the gas price of the calling transaction.
    function drawPrice() public view returns (uint256) {
        return i_vrfV2PlusWrapper.calculateRequestPriceNative(CALLBACK_GAS_LIMIT, 1);
    }

    /// @notice Request the random number. Can only happen once per giveaway. The fee is paid
    ///         from the deposit; send ETH only if the deposit doesn't cover it (excess refunded).
    function draw(uint256 id) external payable returns (uint256 requestId) {
        return _draw(id, msg.value);
    }

    /// @notice True when a giveaway has closed and hasn't been drawn yet.
    function isDrawable(uint256 id) public view returns (bool) {
        Giveaway storage g = _get(id);
        return g.status == Status.Open && block.timestamp >= g.closesAt;
    }

    // ------------------------------------------------------------------
    // Chainlink Automation: draws as soon as a giveaway closes
    // ------------------------------------------------------------------

    /// @notice Chainlink Automation asks this every block (off-chain simulation).
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 n = _giveaways.length;
        uint256 stop = n > UPKEEP_SCAN ? n - UPKEEP_SCAN : 0;
        for (uint256 i = n; i > stop; --i) {
            if (isDrawable(i - 1)) return (true, abi.encode(i - 1));
        }
        return (false, "");
    }

    /// @notice Called by Chainlink Automation when checkUpkeep says a giveaway is ready. Anyone may
    ///         call it; it only ever draws a closed giveaway, paid entirely from its deposit.
    function performUpkeep(bytes calldata performData) external {
        _draw(abi.decode(performData, (uint256)), 0);
    }

    function _draw(uint256 id, uint256 paid) internal returns (uint256 requestId) {
        Giveaway storage g = _get(id);
        if (g.status != Status.Open) revert WrongStatus(g.status);
        if (block.timestamp < g.closesAt) revert StillOpen();
        uint256 supply = zombies.totalSupply();
        if (supply == 0) revert NoTickets();

        uint256 price = drawPrice();
        uint256 deposit = g.feeDeposit;
        if (deposit + paid < price) revert FeeTooLow(price, deposit + paid);

        lockedFees -= deposit;
        g.feePaid = price;
        g.ticketCount = uint32(supply);
        g.requestedAt = uint64(block.timestamp);
        g.status = Status.Drawing;

        (requestId,) = requestRandomnessPayInNative(
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            1,
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
        );
        g.requestId = requestId;
        _giveawayOfRequest[requestId] = id + 1;
        emit DrawRequested(id, requestId, price, uint32(supply));

        // Leftovers: the caller's ETH comes back first, then the unused deposit goes to the owner.
        uint256 fromCaller = price > deposit ? price - deposit : 0;
        uint256 callerRefund = paid - fromCaller;
        uint256 ownerRefund = deposit > price ? deposit - price : 0;
        if (callerRefund > 0) _send(msg.sender, callerRefund);
        if (ownerRefund > 0) {
            // Never let the owner's wallet block a draw: if it refuses ETH, the refund stays
            // here and the owner can take it with withdraw().
            (bool ok,) = owner().call{value: ownerRefund}("");
            ok;
        }
    }

    // ------------------------------------------------------------------
    // 3. Chainlink callback: pick the winner and pay, atomically (must never revert)
    // ------------------------------------------------------------------

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 ref = _giveawayOfRequest[requestId];
        if (ref == 0 || randomWords.length == 0) return;
        uint256 id = ref - 1;
        Giveaway storage g = _giveaways[id];
        if (g.status != Status.Drawing || g.requestId != requestId) return;
        g.randomWord = randomWords[0];
        g.status = Status.Drawn;
        emit RandomnessReceived(id, requestId, randomWords[0]);
        _pickAndPay(id, CALLBACK_ATTEMPTS);
    }

    /// @notice Finish a drawn giveaway if the callback couldn't (no eligible pick within its
    ///         budget, or the transfer failed). Continues the same deterministic sequence.
    function continuePayout(uint256 id) external {
        Giveaway storage g = _get(id);
        if (g.status != Status.Drawn) revert WrongStatus(g.status);
        _pickAndPay(id, CONTINUE_ATTEMPTS);
    }

    /// @notice The Zombie token id drawn on a given attempt (attempt 0 is the first pick).
    function ticketAt(uint256 id, uint32 attempt) public view returns (uint256 tokenId, bool exists) {
        Giveaway storage g = _get(id);
        if (g.status != Status.Drawn && g.status != Status.Completed) revert WrongStatus(g.status);
        uint256 index = uint256(keccak256(abi.encode(g.randomWord, attempt))) % g.ticketCount;
        try zombies.tokenByIndex(index) returns (uint256 t) {
            return (t, true);
        } catch {
            return (0, false);
        }
    }

    function _pickAndPay(uint256 id, uint32 budget) internal {
        Giveaway storage g = _giveaways[id];
        if (g.winner == address(0)) {
            uint32 end = g.attempts + budget;
            for (uint32 a = g.attempts; a < end; ++a) {
                (uint256 tokenId, bool ok) = ticketAt(id, a);
                address holder = ok ? _ownerOf(tokenId) : address(0);
                if (holder != address(0) && holder != owner() && holder != address(this)) {
                    g.winner = holder;
                    g.winningTokenId = tokenId;
                    g.attempts = a + 1;
                    break;
                }
                emit TicketSkipped(id, a, tokenId, holder);
            }
            if (g.winner == address(0)) {
                g.attempts = end;
                emit PayoutPending(id, end);
                return;
            }
        }
        // Effects first; rolled back below if the transfer fails.
        g.status = Status.Completed;
        g.completedAt = uint64(block.timestamp);
        isLockedPrize[g.prizeTokenId] = false;
        try zombies.transferFrom(address(this), g.winner, g.prizeTokenId) {
            emit WinnerPaid(id, g.winner, g.prizeTokenId, g.winningTokenId);
        } catch {
            g.status = Status.Drawn;
            g.completedAt = 0;
            isLockedPrize[g.prizeTokenId] = true;
            emit PayoutPending(id, g.attempts);
        }
    }

    // ------------------------------------------------------------------
    // Owner escape hatches
    // ------------------------------------------------------------------

    /// @notice Cancel before the draw (or if Chainlink never answered for 7 days) and return
    ///         the prize and any unused deposit to the owner. A drawn giveaway can never be cancelled.
    function cancel(uint256 id) external onlyOwner {
        Giveaway storage g = _get(id);
        bool abandoned = g.status == Status.Drawing && block.timestamp >= g.requestedAt + VRF_ABANDON_AFTER;
        if (g.status != Status.Open && !abandoned) revert WrongStatus(g.status);
        uint256 refund = g.status == Status.Open ? g.feeDeposit : 0;
        if (refund > 0) lockedFees -= refund;
        g.status = Status.Cancelled;
        isLockedPrize[g.prizeTokenId] = false;
        emit GiveawayCancelled(id);
        zombies.transferFrom(address(this), owner(), g.prizeTokenId);
        if (refund > 0) _send(owner(), refund);
    }

    /// @notice Return an NFT sent here by mistake. The prize of an unfinished giveaway can never be rescued.
    function rescueToken(address token, uint256 tokenId) external onlyOwner {
        if (token == address(zombies) && isLockedPrize[tokenId]) revert PrizeLocked();
        emit TokenRescued(token, tokenId, owner());
        IERC721(token).transferFrom(address(this), owner(), tokenId);
    }

    /// @notice Withdraw stray ETH. Deposits for giveaways that haven't drawn yet stay locked.
    function withdraw(address payable to) external onlyOwner {
        _send(to, address(this).balance - lockedFees);
    }

    /// @notice Disabled: without an owner, open giveaways could never be cancelled.
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

    function _ownerOf(uint256 tokenId) internal view returns (address) {
        try zombies.ownerOf(tokenId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
