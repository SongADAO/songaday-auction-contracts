// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Song a Day soulbound editions on Ethereum mainnet
/// @notice Each wallet may receive one edition of each song, by purchase or historical supporter entitlement.
/// @dev Original NFTs are referenced only. This contract has no bridge, auction, or original-NFT custody powers.
contract SongADayEditions is ERC1155, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant BATCH_MINT_GAS = 180_000;

    address public immutable originalCollection;
    /// @notice Zero denotes native ETH; otherwise this is the single, trusted ERC20 accepted for purchases.
    address public immutable paymentToken;

    struct Edition {
        uint256 price;
        uint256 openedAt;
        uint256 closesAt;
        uint256 supporterRevision;
        string metadataURI;
        bool registered;
    }

    struct SupporterCheckpoint {
        uint256 revision;
        uint256 validUntil;
    }

    mapping(uint256 songId => Edition) private _editions;
    mapping(address supporter => SupporterCheckpoint[]) private _supporterHistory;
    mapping(address manager => bool) public editionManagers;
    mapping(address manager => bool) public supporterManagers;
    mapping(address manager => bool) public deadlineManagers;
    mapping(uint256 songId => bool) public editionSaleFinalized;
    mapping(uint256 songId => mapping(address recipient => bool)) public hasMinted;
    mapping(uint256 songId => uint256) public totalSupply;
    uint256 public supporterRevision;

    error InvalidAddress();
    error InvalidContract(address account);
    error UnauthorizedEditionManager(address account);
    error UnauthorizedSupporterManager(address account);
    error UnauthorizedDeadlineManager(address account);
    error UnknownEdition(uint256 songId);
    error EditionAlreadyRegistered(uint256 songId);
    error InvalidEditionConfiguration();
    error InvalidEditionDeadline();
    error EditionSaleAlreadyFinalized(uint256 songId);
    error EditionSaleNotEnded(uint256 songId);
    error InvalidSupporterExpiry();
    error InvalidBatchLength();
    error PurchaseWindowClosed(uint256 songId);
    error AlreadyMinted(uint256 songId, address recipient);
    error NotEligibleSupporter(uint256 songId, address recipient);
    error IncorrectPayment(uint256 expected, uint256 actual);
    error IncorrectTokenReceipt(uint256 expected, uint256 actual);
    error Soulbound();
    error OnlySelf();
    error OwnershipRenunciationDisabled();
    error WithdrawalFailed();

    event EditionRegistered(
        uint256 indexed songId,
        uint256 price,
        uint256 openedAt,
        uint256 closesAt,
        uint256 supporterRevision,
        string metadataURI
    );
    event EditionManagerUpdated(address indexed manager, bool enabled);
    event SupporterManagerUpdated(address indexed manager, bool enabled);
    event DeadlineManagerUpdated(address indexed manager, bool enabled);
    event EditionDeadlineExtended(uint256 indexed songId, uint256 previousClosesAt, uint256 newClosesAt);
    event EditionSaleFinalized(uint256 indexed songId, uint256 closesAt);
    event SupporterUpdated(address indexed supporter, uint256 indexed revision, uint256 validUntil);
    event EditionMinted(uint256 indexed songId, address indexed recipient, bool supporter);
    event SupporterMintSkipped(uint256 indexed songId, address indexed recipient);
    event SupporterMintFailed(uint256 indexed songId, address indexed recipient);
    event RevenueWithdrawn(address indexed recipient, uint256 amount);

    constructor(address initialOwner, address originalCollection_, address paymentToken_)
        ERC1155("")
        Ownable(initialOwner)
    {
        if (originalCollection_ == address(0)) revert InvalidAddress();
        if (originalCollection_.code.length == 0) revert InvalidContract(originalCollection_);
        if (paymentToken_ != address(0) && paymentToken_.code.length == 0) {
            revert InvalidContract(paymentToken_);
        }
        originalCollection = originalCollection_;
        paymentToken = paymentToken_;
    }

    modifier onlyEditionManager() {
        if (msg.sender != owner() && !editionManagers[msg.sender]) {
            revert UnauthorizedEditionManager(msg.sender);
        }
        _;
    }

    modifier onlySupporterManager() {
        if (msg.sender != owner() && !supporterManagers[msg.sender]) {
            revert UnauthorizedSupporterManager(msg.sender);
        }
        _;
    }

    modifier onlyDeadlineManager() {
        if (msg.sender != owner() && !deadlineManagers[msg.sender]) {
            revert UnauthorizedDeadlineManager(msg.sender);
        }
        _;
    }

    function setEditionManager(address manager, bool enabled) external onlyOwner {
        if (manager == address(0) || manager == address(this)) revert InvalidAddress();
        editionManagers[manager] = enabled;
        emit EditionManagerUpdated(manager, enabled);
    }

    function setSupporterManager(address manager, bool enabled) external onlyOwner {
        if (manager == address(0) || manager == address(this)) revert InvalidAddress();
        supporterManagers[manager] = enabled;
        emit SupporterManagerUpdated(manager, enabled);
    }

    function setDeadlineManager(address manager, bool enabled) external onlyOwner {
        if (manager == address(0) || manager == address(this)) revert InvalidAddress();
        deadlineManagers[manager] = enabled;
        emit DeadlineManagerUpdated(manager, enabled);
    }

    /// @notice Publishes a song with fixed price, metadata and entitlement snapshot; purchases open immediately.
    /// @dev Prices are raw payment-token units (wei for ETH); USD quoting happens outside this contract.
    function registerEdition(uint256 songId, uint256 price, uint256 closesAt, string calldata metadataURI)
        external
        onlyEditionManager
    {
        if (_editions[songId].registered) revert EditionAlreadyRegistered(songId);
        if (songId == 0 || price == 0 || closesAt <= block.timestamp || bytes(metadataURI).length == 0) {
            revert InvalidEditionConfiguration();
        }
        _editions[songId] = Edition({
            price: price,
            openedAt: block.timestamp,
            closesAt: closesAt,
            supporterRevision: supporterRevision,
            metadataURI: metadataURI,
            registered: true
        });
        emit EditionRegistered(songId, price, block.timestamp, closesAt, supporterRevision, metadataURI);
        emit URI(metadataURI, songId);
    }

    /// @notice Relays a later Base auction deadline without changing any other publication terms.
    /// @dev This role is trusted: the contract cannot verify Base. Delayed relays may reopen a closed window.
    function extendEditionDeadline(uint256 songId, uint256 newClosesAt) external onlyDeadlineManager {
        Edition storage song = _edition(songId);
        if (editionSaleFinalized[songId]) revert EditionSaleAlreadyFinalized(songId);
        uint256 previousClosesAt = song.closesAt;
        if (newClosesAt <= previousClosesAt || newClosesAt <= block.timestamp) {
            revert InvalidEditionDeadline();
        }
        song.closesAt = newClosesAt;
        emit EditionDeadlineExtended(songId, previousClosesAt, newClosesAt);
    }

    /// @notice Permanently locks an ended sale after the operator has verified the final Base auction outcome.
    /// @dev Role-gated because public finalization could lock a stale deadline before an extension is relayed.
    function finalizeEditionSale(uint256 songId) external onlyDeadlineManager {
        Edition storage song = _edition(songId);
        if (editionSaleFinalized[songId]) revert EditionSaleAlreadyFinalized(songId);
        if (block.timestamp < song.closesAt) revert EditionSaleNotEnded(songId);
        editionSaleFinalized[songId] = true;
        emit EditionSaleFinalized(songId, song.closesAt);
    }

    function edition(uint256 songId) external view returns (Edition memory) {
        return _edition(songId);
    }

    function uri(uint256 songId) public view override returns (string memory) {
        return _edition(songId).metadataURI;
    }

    /// @notice Zero removes future eligibility; a future timestamp activates or renews it.
    /// @dev Updates never change entitlement for already published songs.
    function setSupporter(address supporter, uint256 validUntil) external onlySupporterManager {
        _setSupporter(supporter, validUntil);
    }

    function setSupporters(address[] calldata supporters, uint256[] calldata validUntil)
        external
        onlySupporterManager
    {
        uint256 length = supporters.length;
        if (length == 0 || length > MAX_BATCH_SIZE || length != validUntil.length) {
            revert InvalidBatchLength();
        }
        for (uint256 i; i < length; ++i) {
            _setSupporter(supporters[i], validUntil[i]);
        }
    }

    function supporterCheckpointCount(address supporter) external view returns (uint256) {
        return _supporterHistory[supporter].length;
    }

    function supporterCheckpoint(address supporter, uint256 index)
        external
        view
        returns (SupporterCheckpoint memory)
    {
        return _supporterHistory[supporter][index];
    }

    /// @notice Historical eligibility for this song, independent of whether its edition has been minted.
    function isEligibleSupporter(uint256 songId, address supporter) public view returns (bool) {
        Edition storage song = _edition(songId);
        if (supporter == address(0)) return false;
        SupporterCheckpoint[] storage checkpoints = _supporterHistory[supporter];
        // Upper-bound search for the last checkpoint at or before the publication snapshot.
        uint256 low = 0;
        uint256 high = checkpoints.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (checkpoints[mid].revision <= song.supporterRevision) low = mid + 1;
            else high = mid;
        }
        return low != 0 && checkpoints[low - 1].validUntil > song.openedAt;
    }

    /// @notice Purchases for the caller only. ERC20 buyers must first approve this contract.
    function mintPaid(uint256 songId) external payable nonReentrant {
        Edition storage song = _edition(songId);
        if (block.timestamp >= song.closesAt) revert PurchaseWindowClosed(songId);
        if (hasMinted[songId][msg.sender]) revert AlreadyMinted(songId, msg.sender);
        if (paymentToken == address(0)) {
            if (msg.value != song.price) revert IncorrectPayment(song.price, msg.value);
        } else {
            if (msg.value != 0) revert IncorrectPayment(0, msg.value);
            IERC20 token = IERC20(paymentToken);
            uint256 beforeBalance = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), song.price);
            uint256 afterBalance = token.balanceOf(address(this));
            uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
            if (received != song.price) revert IncorrectTokenReceipt(song.price, received);
        }
        _mintEdition(songId, msg.sender, false);
    }

    /// @notice Anyone may pay gas to deliver an entitlement, including after the purchase window closes.
    function mintSupporter(uint256 songId, address recipient) external nonReentrant {
        _mintSupporter(songId, recipient);
    }

    /// @notice Bounded best-effort distribution. A broken recipient cannot revert another recipient's mint.
    /// @dev Failed recipients can retry with mintSupporter, which has no per-recipient gas cap.
    function mintSupporterBatch(uint256 songId, address[] calldata recipients)
        external
        nonReentrant
        returns (uint256 minted, uint256 skipped, uint256 failed)
    {
        _edition(songId);
        uint256 length = recipients.length;
        if (length == 0 || length > MAX_BATCH_SIZE) revert InvalidBatchLength();
        for (uint256 i; i < length; ++i) {
            address recipient = recipients[i];
            if (hasMinted[songId][recipient]) {
                ++skipped;
                emit SupporterMintSkipped(songId, recipient);
                continue;
            }
            bytes memory payload = abi.encodeCall(this.mintSupporterFromBatch, (songId, recipient));
            bool success;
            uint256 gasLimit = BATCH_MINT_GAS;
            // Copy no return data: a malicious receiver can also try to exhaust gas with a huge revert payload.
            assembly ("memory-safe") {
                success := call(gasLimit, address(), 0, add(payload, 0x20), mload(payload), 0, 0)
            }
            if (success) {
                ++minted;
            } else {
                ++failed;
                emit SupporterMintFailed(songId, recipient);
            }
        }
    }

    /// @dev External solely to make each batch mint atomic and independently gas-limited.
    function mintSupporterFromBatch(uint256 songId, address recipient) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _mintSupporter(songId, recipient);
    }

    function withdraw(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (paymentToken == address(0)) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert WithdrawalFailed();
        } else {
            IERC20(paymentToken).safeTransfer(recipient, amount);
        }
        emit RevenueWithdrawn(recipient, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes memory) public pure override {
        revert Soulbound();
    }

    function safeBatchTransferFrom(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
    {
        revert Soulbound();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (from != address(0)) revert Soulbound();
        super._update(from, to, ids, values);
    }

    function _edition(uint256 songId) internal view returns (Edition storage song) {
        song = _editions[songId];
        if (!song.registered) revert UnknownEdition(songId);
    }

    function _setSupporter(address supporter, uint256 validUntil) internal {
        if (supporter == address(0) || supporter == address(this)) revert InvalidAddress();
        if (validUntil != 0 && validUntil <= block.timestamp) revert InvalidSupporterExpiry();
        uint256 revision = ++supporterRevision;
        _supporterHistory[supporter].push(SupporterCheckpoint(revision, validUntil));
        emit SupporterUpdated(supporter, revision, validUntil);
    }

    function _mintSupporter(uint256 songId, address recipient) internal {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (!isEligibleSupporter(songId, recipient)) revert NotEligibleSupporter(songId, recipient);
        if (hasMinted[songId][recipient]) revert AlreadyMinted(songId, recipient);
        _mintEdition(songId, recipient, true);
    }

    function _mintEdition(uint256 songId, address recipient, bool supporter) internal {
        hasMinted[songId][recipient] = true;
        ++totalSupply[songId];
        _mint(recipient, songId, 1, "");
        emit EditionMinted(songId, recipient, supporter);
    }
}
