// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SongADayAuction} from "../src/SongADayAuction.sol";

contract AuctionHostileBidder {
    SongADayAuction public immutable auction;
    bool public reject;
    bool public reenter;
    bool public reentrySucceeded;

    constructor(SongADayAuction target) {
        auction = target;
    }

    function place(uint256 song, uint256 previous) external payable {
        auction.bid{value: msg.value}(song, previous, address(this));
    }

    function configure(bool shouldReject, bool shouldReenter) external {
        reject = shouldReject;
        reenter = shouldReenter;
    }

    function withdraw(address payable to) external {
        auction.withdraw(to);
    }

    receive() external payable {
        require(!reject, "reject");
        if (reenter) {
            (reentrySucceeded,) =
                address(auction).call(abi.encodeCall(auction.withdraw, (payable(address(this)))));
        }
    }
}

contract SongADayAuctionTest is Test {
    SongADayAuction internal auction;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");
    address internal collection = makeAddr("mainnetOriginal");
    string internal constant URI = "ipfs://bafkreib4jnstgdh7u3zxe3sgz7r6k62ze5cgaaj5po4wkvjrdclhefnxae";

    function setUp() public {
        vm.warp(100_000);
        auction = new SongADayAuction(address(this), collection, treasury);
        auction.createAuction(6500, uint64(block.timestamp), uint64(block.timestamp + 1 days), 100, 900, URI);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function place(address bidder, uint256 amount, uint256 expected) internal {
        vm.prank(bidder);
        auction.bid{value: amount}(6500, expected, bidder);
    }

    function end() internal {
        vm.warp(auction.getAuction(6500).endTime);
    }

    function testFirstBidOneWeiNoReserve() public {
        assertEq(auction.minimumBid(6500), 1);
        place(alice, 1, 0);
        assertEq(auction.minimumBid(6500), 2);
        end();
        auction.settle(6500);
        SongADayAuction.Auction memory a = auction.getAuction(6500);
        assertTrue(a.settled);
        assertEq(a.bidder, alice);
        assertEq(a.highestBid, 1);
        assertEq(auction.pendingWithdrawals(treasury), 1);
        assertEq(auction.originalCollection(), collection);
        assertEq(auction.originalChainId(), 1);
    }

    function testOutbidRefundAndProceedsIndependent() public {
        place(alice, 1 ether, 0);
        place(bob, 2 ether, 1 ether);
        assertEq(auction.totalEscrow(), 2 ether);
        assertEq(auction.totalPending(), 1 ether);
        assertEq(auction.pendingWithdrawals(alice), 1 ether);
        vm.prank(alice);
        auction.withdraw(payable(alice));
        assertEq(alice.balance, 100 ether);
        end();
        vm.prank(alice);
        auction.settle(6500);
        assertEq(auction.totalEscrow(), 0);
        assertEq(auction.totalPending(), 2 ether);
        vm.prank(treasury);
        auction.withdraw(payable(treasury));
        assertEq(treasury.balance, 2 ether);
        assertEq(address(auction).balance, 0);
    }

    function testSelfOutbidAccountsForFullRefund() public {
        place(alice, 1 ether, 0);
        place(alice, 2 ether, 1 ether);
        assertEq(auction.pendingWithdrawals(alice), 1 ether);
        end();
        auction.settle(6500);
        assertEq(auction.totalPending(), 3 ether);
        assertEq(address(auction).balance, 3 ether);
    }

    function testStaleAndInsufficientBidsRevertWithoutChangingFunds() public {
        place(alice, 1 ether, 0);
        vm.expectRevert(SongADayAuction.StaleBid.selector);
        place(bob, 2 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SongADayAuction.BidTooLow.selector, 1.01 ether));
        place(bob, 1 ether, 1 ether);
        assertEq(address(auction).balance, 1 ether);
    }

    function testExtensionAndExclusiveEndBoundary() public {
        uint256 originalEnd = auction.getAuction(6500).endTime;
        vm.warp(originalEnd - 1);
        place(alice, 1, 0);
        assertEq(auction.getAuction(6500).endTime, originalEnd + 899);
        vm.expectRevert(SongADayAuction.AuctionNotEnded.selector);
        auction.settle(6500);
        end();
        vm.expectRevert(SongADayAuction.AuctionNotOpen.selector);
        place(bob, 2, 1);
        auction.settle(6500);
    }

    function testScheduledAuctionCannotReceiveEarlyBids() public {
        auction.createAuction(
            6501, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 100, 0, URI
        );
        vm.expectRevert(SongADayAuction.AuctionNotOpen.selector);
        auction.bid{value: 1}(6501, 0, alice);
    }

    function testRecipientFrozenAtSettlementAndOnlyBidderCanChange() public {
        vm.prank(alice);
        auction.bid{value: 1 ether}(6500, 0, bob);
        vm.prank(bob);
        vm.expectRevert(SongADayAuction.Unauthorized.selector);
        auction.setDeliveryRecipient(6500, bob);
        end();
        vm.prank(alice);
        auction.setDeliveryRecipient(6500, treasury);
        auction.settle(6500);
        assertEq(auction.getAuction(6500).recipient, treasury);
        vm.prank(alice);
        vm.expectRevert(SongADayAuction.AuctionFinalized.selector);
        auction.setDeliveryRecipient(6500, alice);
    }

    function testNoBidFinalizationHasNoWinnerOrDebt() public {
        end();
        auction.settle(6500);
        SongADayAuction.Auction memory a = auction.getAuction(6500);
        assertTrue(a.settled);
        assertEq(a.bidder, address(0));
        assertEq(a.recipient, address(0));
        assertEq(auction.totalPending(), 0);
        vm.expectRevert(SongADayAuction.AuctionFinalized.selector);
        auction.settle(6500);
    }

    function testCancelOnlyBeforeAnyBidAndNoReuseOfSongId() public {
        auction.cancelAuction(6500);
        assertTrue(auction.getAuction(6500).cancelled);
        vm.expectRevert(SongADayAuction.AuctionFinalized.selector);
        place(alice, 1, 0);
        vm.expectRevert(SongADayAuction.AuctionAlreadyExists.selector);
        auction.createAuction(6500, uint64(block.timestamp), uint64(block.timestamp + 1 days), 100, 900, URI);
    }

    function testCannotCancelFundedAuction() public {
        place(alice, 1, 0);
        vm.expectRevert(SongADayAuction.AuctionHasBids.selector);
        auction.cancelAuction(6500);
    }

    function testBeneficiaryChangesOnlyAffectFutureAuctions() public {
        auction.setBeneficiary(bob);
        place(alice, 1 ether, 0);
        end();
        auction.settle(6500);
        assertEq(auction.pendingWithdrawals(treasury), 1 ether);
        assertEq(auction.pendingWithdrawals(bob), 0);
    }

    function testHostileBidderCannotBlockOutbidAndCanRedirectWithdrawal() public {
        AuctionHostileBidder hostile = new AuctionHostileBidder(auction);
        hostile.configure(true, false);
        hostile.place{value: 1 ether}(6500, 0);
        place(bob, 2 ether, 1 ether);
        vm.expectRevert(SongADayAuction.TransferFailed.selector);
        hostile.withdraw(payable(address(hostile)));
        assertEq(auction.pendingWithdrawals(address(hostile)), 1 ether);
        hostile.withdraw(payable(alice));
        assertEq(alice.balance, 101 ether);
    }

    function testWithdrawalCallbackCannotDrainOtherCredits() public {
        AuctionHostileBidder hostile = new AuctionHostileBidder(auction);
        hostile.configure(false, true);
        hostile.place{value: 1 ether}(6500, 0);
        place(bob, 2 ether, 1 ether);
        hostile.withdraw(payable(address(hostile)));
        assertFalse(hostile.reentrySucceeded());
        assertEq(address(hostile).balance, 1 ether);
        assertEq(address(auction).balance, 2 ether);
    }

    function testPauseDoesNotTrapFundsOrBlockSettlement() public {
        place(alice, 1 ether, 0);
        place(bob, 2 ether, 1 ether);
        auction.pause();
        vm.expectRevert();
        place(alice, 3 ether, 2 ether);
        vm.prank(alice);
        auction.withdraw(payable(alice));
        end();
        auction.settle(6500);
        vm.prank(treasury);
        auction.withdraw(payable(treasury));
        assertEq(address(auction).balance, 0);
    }

    function testManagerCannotTakeOwnershipOrChangeBeneficiary() public {
        auction.setAuctionManager(alice, true);
        vm.prank(alice);
        auction.createAuction(6501, uint64(block.timestamp), uint64(block.timestamp + 1 days), 100, 900, URI);
        vm.prank(alice);
        vm.expectRevert();
        auction.setBeneficiary(alice);
        vm.prank(alice);
        vm.expectRevert();
        auction.setAuctionManager(bob, true);
        vm.expectRevert(SongADayAuction.OwnershipRequired.selector);
        auction.renounceOwnership();
        auction.transferOwnership(bob);
        assertEq(auction.owner(), address(this));
        vm.prank(bob);
        auction.acceptOwnership();
        assertEq(auction.owner(), bob);
    }

    function testInvalidRegistrationUnknownAndAddressChecks() public {
        vm.expectRevert(SongADayAuction.UnknownAuction.selector);
        auction.getAuction(1);
        vm.expectRevert(SongADayAuction.InvalidTerms.selector);
        auction.createAuction(
            6501, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days), 100, 900, URI
        );
        vm.expectRevert(SongADayAuction.InvalidTerms.selector);
        auction.createAuction(6501, uint64(block.timestamp), uint64(block.timestamp + 1 days), 0, 900, URI);
        vm.expectRevert(SongADayAuction.InvalidAddress.selector);
        auction.bid{value: 1}(6500, 0, address(0));
        vm.expectRevert(SongADayAuction.NoCredit.selector);
        auction.withdraw(payable(alice));
    }

    function testSettleManyIdempotentDuplicatesAndBounded() public {
        end();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 6500;
        ids[1] = 6500;
        auction.settleMany(ids);
        auction.settleMany(ids);
        vm.expectRevert(SongADayAuction.InvalidBatch.selector);
        auction.settleMany(new uint256[](101));
    }

    function testImmediateStartUsesMinedTimestampAfterSigningDelay() public {
        uint64 requestedEnd = uint64(block.timestamp + 2 days);
        vm.warp(block.timestamp + 10 minutes);
        auction.createAuction(6501, 0, requestedEnd, 100, 900, URI);
        SongADayAuction.Auction memory created = auction.getAuction(6501);
        assertEq(created.startTime, block.timestamp);
        assertEq(created.endTime, requestedEnd);
        vm.prank(alice);
        auction.bid{value: 1}(6501, 0, alice);
        assertEq(auction.getAuction(6501).highestBid, 1);
    }

    function testCustomEndCanExceedThirtyDays() public {
        uint64 requestedEnd = uint64(block.timestamp + 365 days);
        auction.createAuction(6501, 0, requestedEnd, 100, 900, URI);
        assertEq(auction.getAuction(6501).endTime, requestedEnd);
    }

    function testImmediateStartRejectsExpiredEndAndInsufficientExtensionDuration() public {
        uint64 requestedEnd = uint64(block.timestamp + 1 days);
        vm.warp(requestedEnd);
        vm.expectRevert(SongADayAuction.InvalidTerms.selector);
        auction.createAuction(6501, 0, requestedEnd, 100, 900, URI);
        vm.warp(requestedEnd + 1);
        vm.expectRevert(SongADayAuction.InvalidTerms.selector);
        auction.createAuction(6501, 0, requestedEnd, 100, 900, URI);
        vm.expectRevert(SongADayAuction.InvalidTerms.selector);
        auction.createAuction(6501, 0, uint64(block.timestamp + 899), 100, 900, URI);
        auction.createAuction(6501, 0, uint64(block.timestamp + 900), 100, 900, URI);
        assertEq(auction.getAuction(6501).startTime, block.timestamp);
    }

    function testFuzzImmediateStartKeepsChosenEnd(uint32 durationSeed, uint32 signingDelaySeed) public {
        uint256 duration = bound(uint256(durationSeed), 901, 3650 days);
        uint256 signingDelay = bound(uint256(signingDelaySeed), 0, duration - 900);
        uint64 requestedEnd = uint64(block.timestamp + duration);
        vm.warp(block.timestamp + signingDelay);
        auction.createAuction(6501, 0, requestedEnd, 100, 900, URI);
        SongADayAuction.Auction memory created = auction.getAuction(6501);
        assertEq(created.startTime, block.timestamp);
        assertEq(created.endTime, requestedEnd);
        assertGe(created.endTime - created.startTime, created.extensionWindow);
    }

    function testFuzzRoundingNeverAllowsEqualBid(uint96 raw, uint16 bps) public {
        uint256 amount = bound(uint256(raw), 1, 10 ether);
        uint16 increment = uint16(bound(uint256(bps), 1, 10_000));
        auction.createAuction(
            6501, uint64(block.timestamp), uint64(block.timestamp + 1 days), increment, 0, URI
        );
        vm.prank(alice);
        auction.bid{value: amount}(6501, 0, alice);
        uint256 required = auction.minimumBid(6501);
        assertGt(required, amount);
        assertEq(required, amount + (amount * increment + 9999) / 10000);
    }
}

contract AuctionHandler is Test {
    SongADayAuction public immutable auction;
    address[3] public actors;
    mapping(uint256 => bytes32) public finalState;

    constructor(SongADayAuction target) {
        auction = target;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    }

    function bid(uint8 actorSeed, uint8 songSeed, uint96 extra) external {
        uint256 song = uint256(songSeed) % 3 + 1;
        SongADayAuction.Auction memory a = auction.getAuction(song);
        if (a.settled || a.cancelled || block.timestamp < a.startTime || block.timestamp >= a.endTime) {
            return;
        }
        address actor = actors[uint256(actorSeed) % 3];
        uint256 amount = auction.minimumBid(song) + uint256(extra) % 10 ether;
        vm.deal(actor, amount);
        vm.prank(actor);
        auction.bid{value: amount}(song, a.highestBid, actor);
    }

    function withdraw(uint8 seed) external {
        address actor = seed % 4 == 3 ? address(0x777) : actors[seed % 3];
        if (auction.pendingWithdrawals(actor) == 0) return;
        vm.prank(actor);
        auction.withdraw(payable(actor));
    }

    function advance(uint32 secondsForward) external {
        vm.warp(block.timestamp + uint256(secondsForward) % 900);
    }

    function settle(uint8 seed) external {
        uint256 song = uint256(seed) % 3 + 1;
        SongADayAuction.Auction memory a = auction.getAuction(song);
        if (a.settled || a.cancelled || block.timestamp < a.endTime) return;
        auction.settle(song);
        finalState[song] = keccak256(abi.encode(auction.getAuction(song)));
    }
}

contract AuctionInvariantTest is StdInvariant, Test {
    SongADayAuction internal auction;
    AuctionHandler internal handler;

    function setUp() public {
        vm.warp(100_000);
        auction = new SongADayAuction(address(this), address(0x721), address(0x777));
        for (uint256 i = 1; i <= 3; ++i) {
            auction.createAuction(
                i, uint64(block.timestamp), uint64(block.timestamp + 1 hours), 100, 300, "ipfs://original"
            );
        }
        handler = new AuctionHandler(auction);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.bid.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantFundsCoverEveryAuctionAndRefund() public view {
        uint256 escrow;
        uint256 pending = auction.pendingWithdrawals(address(0x777));
        for (uint256 i = 1; i <= 3; ++i) {
            SongADayAuction.Auction memory a = auction.getAuction(i);
            if (!a.settled && !a.cancelled) escrow += a.highestBid;
            if (a.settled) assertEq(keccak256(abi.encode(a)), handler.finalState(i));
            pending += auction.pendingWithdrawals(handler.actors(i - 1));
        }
        assertEq(escrow, auction.totalEscrow());
        assertEq(pending, auction.totalPending());
        assertEq(address(auction).balance, escrow + pending);
    }
}
