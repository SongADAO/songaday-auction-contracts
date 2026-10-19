// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Base ETH auctions for existing Ethereum Song A Day originals.
/// @dev Holds funds, never the mainnet NFT. Settlement finalizes an operator delivery instruction;
///      it does NOT prove or perform mainnet delivery. Refunds/proceeds are pull payments.
contract SongADayAuction is Ownable2Step, ReentrancyGuard, Pausable {
    uint256 public constant originalChainId = 1;
    uint256 public constant MAX_BATCH = 100;
    uint256 public constant MAX_EXTENSION = 1 hours;
    address public immutable originalCollection;
    address public beneficiary;
    mapping(address => bool) public auctionManagers;

    struct Auction {
        uint64 startTime;
        uint64 endTime;
        uint16 incrementBps;
        uint32 extensionWindow;
        uint256 highestBid;
        address bidder;
        address recipient;
        address beneficiary;
        bool settled;
        bool cancelled;
        string metadataURI;
    }

    mapping(uint256 => Auction) private _auctions;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalEscrow;
    uint256 public totalPending;

    error Unauthorized();
    error InvalidAddress();
    error InvalidTerms();
    error UnknownAuction();
    error AuctionAlreadyExists();
    error AuctionNotOpen();
    error AuctionNotEnded();
    error AuctionFinalized();
    error AuctionHasBids();
    error StaleBid();
    error BidTooLow(uint256 minimum);
    error NoCredit();
    error TransferFailed();
    error InvalidBatch();
    error OwnershipRequired();

    event AuctionManagerSet(address indexed manager, bool enabled);
    event BeneficiarySet(address indexed beneficiary);
    event AuctionCreated(
        uint256 indexed songId,
        uint64 startTime,
        uint64 endTime,
        uint16 incrementBps,
        uint32 extensionWindow,
        address indexed beneficiary,
        string metadataURI
    );
    event BidPlaced(
        uint256 indexed songId,
        address indexed bidder,
        address indexed recipient,
        uint256 amount,
        uint64 endTime
    );
    event DeliveryRecipientSet(uint256 indexed songId, address indexed bidder, address indexed recipient);
    event AuctionSettled(
        uint256 indexed songId,
        address indexed bidder,
        address indexed recipient,
        uint256 amount,
        address beneficiary
    );
    event AuctionCancelled(uint256 indexed songId);
    event CreditAdded(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, address indexed recipient, uint256 amount);

    modifier onlyManager() {
        if (msg.sender != owner() && !auctionManagers[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address initialOwner, address collection, address initialBeneficiary) Ownable(initialOwner) {
        if (collection == address(0) || initialBeneficiary == address(0)) revert InvalidAddress();
        originalCollection = collection;
        beneficiary = initialBeneficiary;
    }

    function setAuctionManager(address manager, bool enabled) external onlyOwner {
        if (manager == address(0)) revert InvalidAddress();
        auctionManagers[manager] = enabled;
        emit AuctionManagerSet(manager, enabled);
    }

    /// @dev Only affects auctions created after this change.
    function setBeneficiary(address newBeneficiary) external onlyOwner {
        if (newBeneficiary == address(0)) revert InvalidAddress();
        beneficiary = newBeneficiary;
        emit BeneficiarySet(newBeneficiary);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @param startTime Zero opens at the mined block's timestamp, allowing time to sign a transaction.
    function createAuction(
        uint256 songId,
        uint64 startTime,
        uint64 endTime,
        uint16 incrementBps,
        uint32 extensionWindow,
        string calldata metadataURI
    ) external onlyManager whenNotPaused {
        if (_auctions[songId].startTime != 0) revert AuctionAlreadyExists();
        if (startTime == 0) startTime = SafeCast.toUint64(block.timestamp);
        if (
            songId == 0 || startTime == 0 || startTime < block.timestamp || endTime <= startTime
                || incrementBps == 0 || incrementBps > 10_000 || extensionWindow > MAX_EXTENSION
                || extensionWindow > endTime - startTime || bytes(metadataURI).length == 0
        ) revert InvalidTerms();
        _auctions[songId] = Auction({
            startTime: startTime,
            endTime: endTime,
            incrementBps: incrementBps,
            extensionWindow: extensionWindow,
            highestBid: 0,
            bidder: address(0),
            recipient: address(0),
            beneficiary: beneficiary,
            settled: false,
            cancelled: false,
            metadataURI: metadataURI
        });
        emit AuctionCreated(
            songId, startTime, endTime, incrementBps, extensionWindow, beneficiary, metadataURI
        );
    }

    function getAuction(uint256 songId) external view returns (Auction memory) {
        return _auction(songId);
    }

    function minimumBid(uint256 songId) public view returns (uint256) {
        Auction storage auction = _auction(songId);
        if (auction.highestBid == 0) return 1;
        return auction.highestBid
            + Math.mulDiv(auction.highestBid, auction.incrementBps, 10_000, Math.Rounding.Ceil);
    }

    /// @param expectedHighestBid Protects against stale UI data and unexpected mempool ordering.
    /// @param recipient The intended mainnet recipient; distinct from the Base refund payer.
    function bid(uint256 songId, uint256 expectedHighestBid, address recipient)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        Auction storage auction = _auction(songId);
        if (auction.settled || auction.cancelled) revert AuctionFinalized();
        if (block.timestamp < auction.startTime || block.timestamp >= auction.endTime) {
            revert AuctionNotOpen();
        }
        if (recipient == address(0)) revert InvalidAddress();
        if (auction.highestBid != expectedHighestBid) revert StaleBid();
        uint256 minimum = minimumBid(songId);
        if (msg.value < minimum) revert BidTooLow(minimum);

        uint256 previousBid = auction.highestBid;
        address previousBidder = auction.bidder;
        auction.highestBid = msg.value;
        auction.bidder = msg.sender;
        auction.recipient = recipient;
        totalEscrow = totalEscrow - previousBid + msg.value;
        if (previousBid != 0) _credit(previousBidder, previousBid);

        uint256 extendedEnd = block.timestamp + auction.extensionWindow;
        if (extendedEnd > auction.endTime) auction.endTime = SafeCast.toUint64(extendedEnd);
        emit BidPlaced(songId, msg.sender, recipient, msg.value, auction.endTime);
    }

    /// @dev Settlement freezes this address before the Toolkit can prepare mainnet delivery.
    function setDeliveryRecipient(uint256 songId, address recipient) external {
        Auction storage auction = _auction(songId);
        if (auction.settled || auction.cancelled) revert AuctionFinalized();
        if (msg.sender != auction.bidder) revert Unauthorized();
        if (recipient == address(0)) revert InvalidAddress();
        auction.recipient = recipient;
        emit DeliveryRecipientSet(songId, msg.sender, recipient);
    }

    /// @notice Finalizes a sold OR no-bid auction, without any external calls.
    function settle(uint256 songId) external {
        _settle(songId);
    }

    /// @notice Idempotent for already-settled/cancelled IDs; unknown or live IDs revert the batch.
    function settleMany(uint256[] calldata songIds) external {
        if (songIds.length == 0 || songIds.length > MAX_BATCH) revert InvalidBatch();
        for (uint256 i; i < songIds.length; ++i) {
            Auction storage auction = _auction(songIds[i]);
            if (!auction.settled && !auction.cancelled) _settle(songIds[i]);
        }
    }

    function cancelAuction(uint256 songId) external onlyManager {
        Auction storage auction = _auction(songId);
        if (auction.settled || auction.cancelled) revert AuctionFinalized();
        if (auction.highestBid != 0) revert AuctionHasBids();
        auction.cancelled = true;
        emit AuctionCancelled(songId);
    }

    /// @notice A refund/proceeds owner can send their entire credit to a compatible wallet.
    /// @dev Pausing bidding never blocks withdrawal or finalization.
    function withdraw(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidAddress();
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoCredit();
        pendingWithdrawals[msg.sender] = 0;
        totalPending -= amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(msg.sender, recipient, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _settle(uint256 songId) private {
        Auction storage auction = _auction(songId);
        if (auction.settled || auction.cancelled) revert AuctionFinalized();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        auction.settled = true;
        uint256 amount = auction.highestBid;
        if (amount != 0) {
            totalEscrow -= amount;
            _credit(auction.beneficiary, amount);
        }
        emit AuctionSettled(songId, auction.bidder, auction.recipient, amount, auction.beneficiary);
    }

    function _credit(address account, uint256 amount) private {
        pendingWithdrawals[account] += amount;
        totalPending += amount;
        emit CreditAdded(account, amount);
    }

    function _auction(uint256 songId) private view returns (Auction storage auction) {
        auction = _auctions[songId];
        if (auction.startTime == 0) revert UnknownAuction();
    }
}
