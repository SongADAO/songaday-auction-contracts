// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SongADayEditions} from "../src/SongADayEditions.sol";
import {
    EditionOriginal,
    EditionToken,
    EditionFalseToken,
    EditionFeeToken,
    EditionReentrantToken,
    EditionRejectingReceiver,
    EditionGasBurningReceiver,
    EditionReturnBombReceiver,
    EditionReentrantReceiver,
    EditionExpensiveReceiver,
    EditionRejectingBuyer
} from "./mocks/EditionMocks.sol";

contract SongADayEditionsTest is Test {
    SongADayEditions internal editions;
    EditionOriginal internal original;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal publisher = makeAddr("publisher");
    address internal listManager = makeAddr("listManager");
    uint256 internal constant SONG = 6500;
    uint256 internal constant PRICE = 0.0004 ether;

    function setUp() public {
        vm.warp(1_000_000);
        original = new EditionOriginal();
        editions = new SongADayEditions(address(this), address(original), address(0));
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    receive() external payable {}

    function publish(uint256 songId) internal {
        editions.registerEdition(songId, PRICE, block.timestamp + 1 days, "ipfs://song-metadata");
    }

    function activate(address supporter) internal {
        editions.setSupporter(supporter, block.timestamp + 30 days);
    }

    function testConstructorAndInterfaces() public view {
        assertEq(editions.owner(), address(this));
        assertEq(editions.originalCollection(), address(original));
        assertEq(editions.paymentToken(), address(0));
        assertTrue(editions.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertFalse(editions.supportsInterface(0xffffffff));
    }

    function testConstructorRejectsInvalidAddresses() public {
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        new SongADayEditions(address(this), address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.InvalidContract.selector, alice));
        new SongADayEditions(address(this), alice, address(0));
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.InvalidContract.selector, alice));
        new SongADayEditions(address(this), address(original), alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SongADayEditions(address(0), address(original), address(0));
    }

    function testPublicationFreezesPriceMetadataAndSnapshot() public {
        activate(alice);
        publish(SONG);
        SongADayEditions.Edition memory song = editions.edition(SONG);
        assertEq(song.price, PRICE);
        assertEq(song.openedAt, block.timestamp);
        assertEq(song.closesAt, block.timestamp + 1 days);
        assertEq(song.supporterRevision, 1);
        assertTrue(song.registered);
        assertEq(editions.uri(SONG), "ipfs://song-metadata");
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.EditionAlreadyRegistered.selector, SONG));
        editions.registerEdition(SONG, 2 * PRICE, block.timestamp + 2 days, "ipfs://replacement");
    }

    function testRegistrationRequiresPositivePriceFutureCloseAndURI() public {
        vm.expectRevert(SongADayEditions.InvalidEditionConfiguration.selector);
        editions.registerEdition(SONG, 0, block.timestamp + 1 days, "ipfs://metadata");
        vm.expectRevert(SongADayEditions.InvalidEditionConfiguration.selector);
        editions.registerEdition(SONG, PRICE, block.timestamp, "ipfs://metadata");
        vm.expectRevert(SongADayEditions.InvalidEditionConfiguration.selector);
        editions.registerEdition(SONG, PRICE, block.timestamp + 1 days, "");
    }

    function testRoleSeparationAndRevocation() public {
        editions.setEditionManager(publisher, true);
        editions.setSupporterManager(listManager, true);
        vm.prank(publisher);
        editions.registerEdition(SONG, PRICE, block.timestamp + 1 days, "ipfs://metadata");
        vm.prank(listManager);
        editions.setSupporter(alice, block.timestamp + 30 days);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(SongADayEditions.UnauthorizedSupporterManager.selector, publisher)
        );
        editions.setSupporter(bob, block.timestamp + 30 days);
        vm.prank(listManager);
        vm.expectRevert(
            abi.encodeWithSelector(SongADayEditions.UnauthorizedEditionManager.selector, listManager)
        );
        editions.registerEdition(SONG + 1, PRICE, block.timestamp + 1 days, "ipfs://metadata");
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, publisher));
        editions.withdraw(payable(publisher), 0);
        vm.prank(listManager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, listManager));
        editions.setEditionManager(listManager, true);
        editions.setEditionManager(publisher, false);
        editions.setSupporterManager(listManager, false);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(SongADayEditions.UnauthorizedEditionManager.selector, publisher)
        );
        editions.registerEdition(SONG + 1, PRICE, block.timestamp + 1 days, "ipfs://metadata");
        vm.prank(listManager);
        vm.expectRevert(
            abi.encodeWithSelector(SongADayEditions.UnauthorizedSupporterManager.selector, listManager)
        );
        editions.setSupporter(alice, 0);
    }

    function testInvalidManagerAndSupporterInputs() public {
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.setEditionManager(address(0), true);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.setSupporterManager(address(editions), true);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.setSupporter(address(0), block.timestamp + 1);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.setSupporter(address(editions), block.timestamp + 1);
        vm.expectRevert(SongADayEditions.InvalidSupporterExpiry.selector);
        editions.setSupporter(alice, block.timestamp);
        vm.expectRevert(SongADayEditions.InvalidSupporterExpiry.selector);
        editions.setSupporter(alice, block.timestamp - 1);
        assertEq(editions.supporterRevision(), 0);
    }

    function testTwoStepOwnershipAndNoRenunciation() public {
        editions.transferOwnership(alice);
        assertEq(editions.owner(), address(this));
        assertEq(editions.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        editions.acceptOwnership();
        vm.prank(alice);
        editions.acceptOwnership();
        assertEq(editions.owner(), alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        editions.setEditionManager(publisher, true);
        vm.prank(alice);
        vm.expectRevert(SongADayEditions.OwnershipRenunciationDisabled.selector);
        editions.renounceOwnership();
    }

    function testUnknownEditionInputsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG));
        editions.edition(SONG);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG));
        editions.uri(SONG);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG));
        editions.isEligibleSupporter(SONG, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG));
        editions.mintPaid{value: PRICE}(SONG);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG));
        editions.mintSupporter(SONG, alice);
    }

    function testPaidETHMintAndWithdrawal() public {
        publish(SONG);
        vm.prank(alice);
        editions.mintPaid{value: PRICE}(SONG);
        assertEq(editions.balanceOf(alice, SONG), 1);
        assertTrue(editions.hasMinted(SONG, alice));
        assertEq(editions.totalSupply(SONG), 1);
        assertEq(address(editions).balance, PRICE);
        uint256 beforeBalance = bob.balance;
        editions.withdraw(payable(bob), PRICE);
        assertEq(bob.balance, beforeBalance + PRICE);
        assertEq(address(editions).balance, 0);
    }

    function testFuzzPaidRequiresExactPrice(uint256 payment) public {
        vm.assume(payment != PRICE);
        vm.deal(alice, payment);
        publish(SONG);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.IncorrectPayment.selector, PRICE, payment));
        editions.mintPaid{value: payment}(SONG);
        assertFalse(editions.hasMinted(SONG, alice));
        assertEq(editions.totalSupply(SONG), 0);
    }

    function testPaidWindowBoundaryAndDuplicate() public {
        publish(SONG);
        vm.prank(alice);
        editions.mintPaid{value: PRICE}(SONG);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.AlreadyMinted.selector, SONG, alice));
        editions.mintPaid{value: PRICE}(SONG);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.PurchaseWindowClosed.selector, SONG));
        editions.mintPaid{value: PRICE}(SONG);
        assertEq(address(editions).balance, PRICE);
    }

    function testSupporterMintSponsoredAndSurvivesRemovalAndClose() public {
        activate(alice);
        publish(SONG);
        editions.setSupporter(alice, 0);
        vm.warp(block.timestamp + 40 days);
        vm.prank(bob);
        editions.mintSupporter(SONG, alice);
        assertEq(editions.balanceOf(alice, SONG), 1);
        assertEq(address(editions).balance, 0);
        publish(SONG + 1);
        assertFalse(editions.isEligibleSupporter(SONG + 1, alice));
    }

    function testRenewalsAreNotRetroactive() public {
        publish(SONG);
        activate(alice);
        assertFalse(editions.isEligibleSupporter(SONG, alice));
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.NotEligibleSupporter.selector, SONG, alice));
        editions.mintSupporter(SONG, alice);
        publish(SONG + 1);
        assertTrue(editions.isEligibleSupporter(SONG + 1, alice));
        editions.mintSupporter(SONG + 1, alice);
    }

    function testExpiryBoundaryIsNotEligibleAndLaterRenewalDoesNotChangeIt() public {
        editions.setSupporter(alice, block.timestamp + 10);
        publish(SONG);
        vm.warp(block.timestamp + 10);
        publish(SONG + 1);
        assertTrue(editions.isEligibleSupporter(SONG, alice));
        assertFalse(editions.isEligibleSupporter(SONG + 1, alice));
        activate(alice);
        assertFalse(editions.isEligibleSupporter(SONG + 1, alice));
        publish(SONG + 2);
        assertTrue(editions.isEligibleSupporter(SONG + 2, alice));
    }

    function testSameBlockRevisionOrderingAndInterleavedAddresses() public {
        activate(alice);
        publish(SONG);
        editions.setSupporter(alice, 0);
        activate(bob);
        publish(SONG + 1);
        activate(alice);
        publish(SONG + 2);
        assertTrue(editions.isEligibleSupporter(SONG, alice));
        assertFalse(editions.isEligibleSupporter(SONG, bob));
        assertFalse(editions.isEligibleSupporter(SONG + 1, alice));
        assertTrue(editions.isEligibleSupporter(SONG + 1, bob));
        assertTrue(editions.isEligibleSupporter(SONG + 2, alice));
        assertEq(editions.supporterCheckpointCount(alice), 3);
        SongADayEditions.SupporterCheckpoint memory checkpoint = editions.supporterCheckpoint(alice, 1);
        assertEq(checkpoint.revision, 2);
        assertEq(checkpoint.validUntil, 0);
    }

    function testFuzzSnapshotSearchAcrossHistory(uint8 countSeed, uint8 snapshotSeed) public {
        uint256 count = bound(uint256(countSeed), 1, 64);
        uint256 snapshot = bound(uint256(snapshotSeed), 1, count);
        for (uint256 i = 1; i <= count; ++i) {
            editions.setSupporter(alice, i % 2 == 1 ? block.timestamp + 1 days : 0);
            activate(bob);
            if (i == snapshot) publish(SONG);
        }
        assertEq(editions.isEligibleSupporter(SONG, alice), snapshot % 2 == 1);
        assertEq(editions.edition(SONG).supporterRevision, snapshot * 2);
    }

    function testPaidAndSupporterMintsShareDeduplication() public {
        activate(alice);
        activate(bob);
        publish(SONG);
        vm.prank(alice);
        editions.mintPaid{value: PRICE}(SONG);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.AlreadyMinted.selector, SONG, alice));
        editions.mintSupporter(SONG, alice);
        editions.mintSupporter(SONG, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.AlreadyMinted.selector, SONG, bob));
        editions.mintPaid{value: PRICE}(SONG);
        assertEq(editions.totalSupply(SONG), 2);
        assertEq(address(editions).balance, PRICE);
    }

    function testSupporterInputsAndSelfHelper() public {
        publish(SONG);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.mintSupporter(SONG, address(0));
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.mintSupporter(SONG, address(editions));
        assertFalse(editions.isEligibleSupporter(SONG, address(0)));
        vm.expectRevert(SongADayEditions.OnlySelf.selector);
        editions.mintSupporterFromBatch(SONG, alice);
    }

    function testSoulboundCannotTransferApproveOrBurn() public {
        activate(alice);
        publish(SONG);
        editions.mintSupporter(SONG, alice);
        vm.startPrank(alice);
        vm.expectRevert(SongADayEditions.Soulbound.selector);
        editions.safeTransferFrom(alice, bob, SONG, 1, "");
        vm.expectRevert(SongADayEditions.Soulbound.selector);
        editions.safeTransferFrom(alice, address(0), SONG, 1, "");
        vm.expectRevert(SongADayEditions.Soulbound.selector);
        editions.setApprovalForAll(bob, true);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = SONG;
        values[0] = 1;
        vm.expectRevert(SongADayEditions.Soulbound.selector);
        editions.safeBatchTransferFrom(alice, bob, ids, values, "");
        vm.stopPrank();
        assertFalse(editions.isApprovedForAll(alice, bob));
        assertEq(editions.balanceOf(alice, SONG), 1);
    }

    function testBatchSkipsDuplicatesAndIsolatesRejectingAndIneligibleRecipients() public {
        EditionRejectingReceiver rejected = new EditionRejectingReceiver();
        activate(alice);
        activate(bob);
        activate(address(rejected));
        publish(SONG);
        address[] memory recipients = new address[](6);
        recipients[0] = alice;
        recipients[1] = address(rejected);
        recipients[2] = alice;
        recipients[3] = address(0);
        recipients[4] = publisher;
        recipients[5] = bob;
        (uint256 minted, uint256 skipped, uint256 failed) = editions.mintSupporterBatch(SONG, recipients);
        assertEq(minted, 2);
        assertEq(skipped, 1);
        assertEq(failed, 3);
        assertEq(editions.balanceOf(alice, SONG), 1);
        assertEq(editions.balanceOf(bob, SONG), 1);
        assertEq(editions.balanceOf(address(rejected), SONG), 0);
        assertFalse(editions.hasMinted(SONG, address(rejected)));
        assertEq(editions.totalSupply(SONG), 2);
    }

    function testBatchGasBurnAndReturnBombCannotBlockLaterRecipients() public {
        EditionGasBurningReceiver burner = new EditionGasBurningReceiver();
        EditionReturnBombReceiver bomber = new EditionReturnBombReceiver();
        activate(address(burner));
        activate(address(bomber));
        activate(alice);
        publish(SONG);
        address[] memory recipients = new address[](3);
        recipients[0] = address(burner);
        recipients[1] = address(bomber);
        recipients[2] = alice;
        (uint256 minted, uint256 skipped, uint256 failed) =
            editions.mintSupporterBatch{gas: 1_000_000}(SONG, recipients);
        assertEq(minted, 1);
        assertEq(skipped, 0);
        assertEq(failed, 2);
        assertEq(editions.balanceOf(alice, SONG), 1);
        assertEq(editions.totalSupply(SONG), 1);
    }

    function testBatchAndListUpdateBounds() public {
        publish(SONG);
        address[] memory empty = new address[](0);
        vm.expectRevert(SongADayEditions.InvalidBatchLength.selector);
        editions.mintSupporterBatch(SONG, empty);
        address[] memory tooMany = new address[](51);
        vm.expectRevert(SongADayEditions.InvalidBatchLength.selector);
        editions.mintSupporterBatch(SONG, tooMany);
        vm.expectRevert(SongADayEditions.InvalidBatchLength.selector);
        editions.setSupporters(empty, new uint256[](0));
        vm.expectRevert(SongADayEditions.InvalidBatchLength.selector);
        editions.setSupporters(tooMany, new uint256[](51));
        address[] memory single = new address[](1);
        single[0] = alice;
        vm.expectRevert(SongADayEditions.InvalidBatchLength.selector);
        editions.setSupporters(single, new uint256[](2));
    }

    function testBatchSupporterUpdateIsAtomicAndRevisioned() public {
        address[] memory recipients = new address[](2);
        uint256[] memory expiries = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        expiries[0] = block.timestamp + 30 days;
        expiries[1] = block.timestamp + 1 days;
        editions.setSupporters(recipients, expiries);
        publish(SONG);
        assertTrue(editions.isEligibleSupporter(SONG, alice));
        assertTrue(editions.isEligibleSupporter(SONG, bob));
        assertEq(editions.supporterRevision(), 2);
        expiries[1] = block.timestamp;
        vm.expectRevert(SongADayEditions.InvalidSupporterExpiry.selector);
        editions.setSupporters(recipients, expiries);
        assertEq(editions.supporterRevision(), 2);
        assertEq(editions.supporterCheckpointCount(alice), 1);
    }

    function testRejectingIndividualMintRollsBackAllState() public {
        EditionRejectingReceiver rejected = new EditionRejectingReceiver();
        activate(address(rejected));
        publish(SONG);
        vm.expectRevert("Edition rejected");
        editions.mintSupporter(SONG, address(rejected));
        assertFalse(editions.hasMinted(SONG, address(rejected)));
        assertEq(editions.totalSupply(SONG), 0);
    }

    function testReceiverReentrancyDuringPaidMintIsBlocked() public {
        EditionReentrantReceiver receiver = new EditionReentrantReceiver();
        activate(address(receiver));
        publish(SONG);
        receiver.configure(
            address(editions), abi.encodeCall(editions.mintSupporter, (SONG, address(receiver)))
        );
        receiver.buy{value: PRICE}(editions, SONG);
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(editions.totalSupply(SONG), 1);
        assertEq(address(editions).balance, PRICE);
    }

    function testReceiverReentrancyDuringBatchCannotCallAnotherMintOrHelper() public {
        EditionReentrantReceiver receiver = new EditionReentrantReceiver();
        activate(address(receiver));
        activate(alice);
        publish(SONG);
        receiver.configure(address(editions), abi.encodeCall(editions.mintSupporter, (SONG, alice)));
        address[] memory recipients = new address[](2);
        recipients[0] = address(receiver);
        recipients[1] = alice;
        (uint256 minted,,) = editions.mintSupporterBatch(SONG, recipients);
        assertEq(minted, 2);
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        publish(SONG + 1);
        receiver.configure(
            address(editions), abi.encodeCall(editions.mintSupporterFromBatch, (SONG + 1, alice))
        );
        editions.mintSupporter(SONG + 1, address(receiver));
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.reentryError(), SongADayEditions.OnlySelf.selector);
        assertFalse(editions.hasMinted(SONG + 1, alice));
    }

    function testWithdrawalChecksAndUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        editions.withdraw(payable(alice), 0);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.withdraw(payable(address(0)), 0);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.withdraw(payable(address(editions)), 0);
        vm.expectRevert(SongADayEditions.WithdrawalFailed.selector);
        editions.withdraw(payable(alice), 1);
        vm.deal(address(editions), 1);
        EditionRejectingReceiver rejected = new EditionRejectingReceiver();
        vm.expectRevert(SongADayEditions.WithdrawalFailed.selector);
        editions.withdraw(payable(address(rejected)), 1);
        assertEq(address(editions).balance, 1);
    }

    function testMaximumBatchDeliversToFiftySupporters() public {
        address[] memory recipients = new address[](50);
        uint256[] memory expiries = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            recipients[i] = address(uint160(0x10000 + i));
            expiries[i] = block.timestamp + 30 days;
        }
        editions.setSupporters(recipients, expiries);
        publish(SONG);
        (uint256 minted, uint256 skipped, uint256 failed) = editions.mintSupporterBatch(SONG, recipients);
        assertEq(minted, 50);
        assertEq(skipped, 0);
        assertEq(failed, 0);
        assertEq(editions.totalSupply(SONG), 50);
        for (uint256 i; i < 50; ++i) {
            assertEq(editions.balanceOf(recipients[i], SONG), 1);
        }
    }

    function testExpensiveReceiverCanRetryIndividuallyAfterBatchFailure() public {
        EditionExpensiveReceiver receiver = new EditionExpensiveReceiver();
        activate(address(receiver));
        activate(alice);
        publish(SONG);
        address[] memory recipients = new address[](2);
        recipients[0] = address(receiver);
        recipients[1] = alice;
        (uint256 minted,, uint256 failed) = editions.mintSupporterBatch(SONG, recipients);
        assertEq(minted, 1);
        assertEq(failed, 1);
        assertFalse(editions.hasMinted(SONG, address(receiver)));
        assertEq(receiver.values(0), 0);
        editions.mintSupporter(SONG, address(receiver));
        assertEq(receiver.values(0), 1);
        assertEq(receiver.values(11), 12);
        assertEq(editions.balanceOf(address(receiver), SONG), 1);
        assertEq(editions.totalSupply(SONG), 2);
    }

    function testRejectedPaidMintRollsBackETHAndTokenPayment() public {
        EditionRejectingBuyer receiver = new EditionRejectingBuyer();
        publish(SONG);
        vm.expectRevert("Edition rejected");
        receiver.buy{value: PRICE}(editions, SONG);
        assertEq(address(editions).balance, 0);
        assertFalse(editions.hasMinted(SONG, address(receiver)));
        EditionToken token = new EditionToken();
        SongADayEditions tokenEditions =
            new SongADayEditions(address(this), address(original), address(token));
        tokenEditions.registerEdition(SONG, 1_000_000, block.timestamp + 1 days, "ipfs://metadata");
        token.mint(address(receiver), 1_000_000);
        vm.expectRevert("Edition rejected");
        receiver.buyWithToken(tokenEditions, token, SONG, 1_000_000);
        assertEq(token.balanceOf(address(receiver)), 1_000_000);
        assertEq(token.balanceOf(address(tokenEditions)), 0);
        assertFalse(tokenEditions.hasMinted(SONG, address(receiver)));
        assertEq(tokenEditions.totalSupply(SONG), 0);
    }

    function testERC20DollarPaymentAndWithdrawal() public {
        EditionToken token = new EditionToken();
        SongADayEditions tokenEditions =
            new SongADayEditions(address(this), address(original), address(token));
        tokenEditions.registerEdition(SONG, 1_000_000, block.timestamp + 1 days, "ipfs://metadata");
        token.mint(alice, 2_000_000);
        vm.startPrank(alice);
        token.approve(address(tokenEditions), 1_000_000);
        tokenEditions.mintPaid(SONG);
        vm.stopPrank();
        assertEq(token.balanceOf(address(tokenEditions)), 1_000_000);
        assertEq(token.balanceOf(alice), 1_000_000);
        assertEq(tokenEditions.balanceOf(alice, SONG), 1);
        tokenEditions.withdraw(payable(bob), 1_000_000);
        assertEq(token.balanceOf(bob), 1_000_000);
    }

    function testERC20RejectsETHOrMissingAllowance() public {
        EditionToken token = new EditionToken();
        SongADayEditions tokenEditions =
            new SongADayEditions(address(this), address(original), address(token));
        tokenEditions.registerEdition(SONG, 1_000_000, block.timestamp + 1 days, "ipfs://metadata");
        token.mint(alice, 1_000_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.IncorrectPayment.selector, 0, 1));
        tokenEditions.mintPaid{value: 1}(SONG);
        vm.prank(alice);
        vm.expectRevert();
        tokenEditions.mintPaid(SONG);
        assertFalse(tokenEditions.hasMinted(SONG, alice));
        assertEq(tokenEditions.totalSupply(SONG), 0);
    }

    function testFalseERC20CannotMint() public {
        EditionFalseToken token = new EditionFalseToken();
        SongADayEditions tokenEditions =
            new SongADayEditions(address(this), address(original), address(token));
        tokenEditions.registerEdition(SONG, 1_000_000, block.timestamp + 1 days, "ipfs://metadata");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        tokenEditions.mintPaid(SONG);
        assertFalse(tokenEditions.hasMinted(SONG, alice));
        assertEq(tokenEditions.totalSupply(SONG), 0);
    }

    function testFeeERC20CannotUnderpayAndTransferRollsBack() public {
        EditionFeeToken token = new EditionFeeToken();
        SongADayEditions tokenEditions =
            new SongADayEditions(address(this), address(original), address(token));
        tokenEditions.registerEdition(SONG, 1_000_000, block.timestamp + 1 days, "ipfs://metadata");
        token.mint(alice, 1_000_000);
        vm.startPrank(alice);
        token.approve(address(tokenEditions), 1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(SongADayEditions.IncorrectTokenReceipt.selector, 1_000_000, 990_000)
        );
        tokenEditions.mintPaid(SONG);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1_000_000);
        assertEq(token.balanceOf(address(tokenEditions)), 0);
        assertFalse(tokenEditions.hasMinted(SONG, alice));
        assertEq(tokenEditions.totalSupply(SONG), 0);
    }

    function testERC20TransferCallbackReentrancyIsBlocked() public {
        EditionReentrantToken token = new EditionReentrantToken();
        SongADayEditions tokenEditions =
            new SongADayEditions(address(this), address(original), address(token));
        tokenEditions.registerEdition(SONG, 1_000_000, block.timestamp + 1 days, "ipfs://metadata");
        token.configure(tokenEditions, SONG);
        token.mint(alice, 1_000_000);
        vm.startPrank(alice);
        token.approve(address(tokenEditions), 1_000_000);
        tokenEditions.mintPaid(SONG);
        vm.stopPrank();
        assertFalse(token.reentrySucceeded());
        assertEq(tokenEditions.totalSupply(SONG), 1);
        assertEq(tokenEditions.balanceOf(address(token), SONG), 0);
    }
}
