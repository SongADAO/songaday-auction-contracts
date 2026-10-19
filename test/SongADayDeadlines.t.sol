// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SongADayAuction} from "../src/SongADayAuction.sol";
import {SongADayEditions} from "../src/SongADayEditions.sol";
import {EditionOriginal} from "./mocks/EditionMocks.sol";

contract SongADayDeadlinesTest is Test {
    SongADayEditions internal editions;
    address internal relay = makeAddr("relay");
    address internal publisher = makeAddr("publisher");
    address internal listManager = makeAddr("listManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant SONG = 6500;
    uint256 internal constant PRICE = 0.0004 ether;
    uint256 internal initialClose;

    function setUp() public {
        vm.warp(1_000_000);
        editions = new SongADayEditions(address(this), address(new EditionOriginal()), address(0));
        editions.setDeadlineManager(relay, true);
        editions.setEditionManager(publisher, true);
        editions.setSupporterManager(listManager, true);
        editions.setSupporter(alice, block.timestamp + 30 days);
        initialClose = block.timestamp + 1 days;
        editions.registerEdition(SONG, PRICE, initialClose, "ipfs://edition");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function extend(uint256 closesAt) internal {
        vm.prank(relay);
        editions.extendEditionDeadline(SONG, closesAt);
    }

    function finalize() internal {
        vm.prank(relay);
        editions.finalizeEditionSale(SONG);
    }

    function testExtensionPreservesPriceMetadataAndSupporterSnapshot() public {
        SongADayEditions.Edition memory beforeExtension = editions.edition(SONG);
        editions.setSupporter(alice, 0);
        editions.setSupporter(bob, block.timestamp + 30 days);
        extend(initialClose + 15 minutes);
        SongADayEditions.Edition memory afterExtension = editions.edition(SONG);
        assertEq(afterExtension.closesAt, initialClose + 15 minutes);
        assertEq(afterExtension.price, beforeExtension.price);
        assertEq(afterExtension.openedAt, beforeExtension.openedAt);
        assertEq(afterExtension.metadataURI, beforeExtension.metadataURI);
        assertEq(afterExtension.supporterRevision, beforeExtension.supporterRevision);
        assertEq(afterExtension.registered, beforeExtension.registered);
        assertTrue(editions.isEligibleSupporter(SONG, alice));
        assertFalse(editions.isEligibleSupporter(SONG, bob));
    }

    function testDelayedRelayReopensOnlyUntilRelayedDeadline() public {
        vm.warp(initialClose);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.PurchaseWindowClosed.selector, SONG));
        editions.mintPaid{value: PRICE}(SONG);
        vm.warp(initialClose + 5 minutes);
        extend(initialClose + 15 minutes);
        vm.prank(alice);
        editions.mintPaid{value: PRICE}(SONG);
        vm.warp(initialClose + 15 minutes);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.PurchaseWindowClosed.selector, SONG));
        editions.mintPaid{value: PRICE}(SONG);
        assertEq(editions.totalSupply(SONG), 1);
        assertEq(address(editions).balance, PRICE);
    }

    function testDeadlineMustStrictlyIncreaseAndRemainFuture() public {
        vm.expectRevert(SongADayEditions.InvalidEditionDeadline.selector);
        extend(initialClose);
        vm.expectRevert(SongADayEditions.InvalidEditionDeadline.selector);
        extend(initialClose - 1);
        vm.warp(initialClose + 15 minutes);
        vm.expectRevert(SongADayEditions.InvalidEditionDeadline.selector);
        extend(block.timestamp);
        vm.expectRevert(SongADayEditions.InvalidEditionDeadline.selector);
        extend(block.timestamp - 1);
        extend(block.timestamp + 1);
        assertEq(editions.edition(SONG).closesAt, block.timestamp + 1);
    }

    function testOnlyDedicatedDeadlineRoleCanChangeOrFinalizeDeadline() public {
        address[3] memory unauthorized = [publisher, listManager, alice];
        for (uint256 i; i < unauthorized.length; ++i) {
            address actor = unauthorized[i];
            vm.prank(actor);
            vm.expectRevert(
                abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, actor)
            );
            editions.extendEditionDeadline(SONG, initialClose + 1);
            vm.prank(actor);
            vm.expectRevert(
                abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, actor)
            );
            editions.finalizeEditionSale(SONG);
        }
        vm.warp(initialClose);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, alice));
        editions.finalizeEditionSale(SONG);
        assertFalse(editions.editionSaleFinalized(SONG));
    }

    function testDeadlineRoleCannotPublishManageSupportersWithdrawOrGrantRoles() public {
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnauthorizedEditionManager.selector, relay));
        editions.registerEdition(SONG + 1, PRICE, initialClose, "ipfs://new");
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnauthorizedSupporterManager.selector, relay));
        editions.setSupporter(bob, initialClose);
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relay));
        editions.withdraw(payable(relay), 0);
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relay));
        editions.setDeadlineManager(alice, true);
    }

    function testDeadlineRoleRevocationIsImmediate() public {
        editions.setDeadlineManager(relay, false);
        assertFalse(editions.deadlineManagers(relay));
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, relay));
        extend(initialClose + 1);
        vm.warp(initialClose);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, relay));
        finalize();
        editions.finalizeEditionSale(SONG);
        assertTrue(editions.editionSaleFinalized(SONG));
    }

    function testInvalidDeadlineManagerAddresses() public {
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.setDeadlineManager(address(0), true);
        vm.expectRevert(SongADayEditions.InvalidAddress.selector);
        editions.setDeadlineManager(address(editions), true);
    }

    function testUnknownEditionCannotExtendOrFinalize() public {
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG + 1));
        editions.extendEditionDeadline(SONG + 1, initialClose);
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnknownEdition.selector, SONG + 1));
        editions.finalizeEditionSale(SONG + 1);
    }

    function testFinalizationOnlyAfterLatestDeadlineAndPermanentlyLocks() public {
        extend(initialClose + 15 minutes);
        vm.warp(initialClose);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.EditionSaleNotEnded.selector, SONG));
        finalize();
        vm.warp(initialClose + 15 minutes);
        finalize();
        assertTrue(editions.editionSaleFinalized(SONG));
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.EditionSaleAlreadyFinalized.selector, SONG));
        extend(initialClose + 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.EditionSaleAlreadyFinalized.selector, SONG));
        editions.extendEditionDeadline(SONG, initialClose + 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.EditionSaleAlreadyFinalized.selector, SONG));
        finalize();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.PurchaseWindowClosed.selector, SONG));
        editions.mintPaid{value: PRICE}(SONG);
    }

    function testFinalizationPreservesHistoricalSupporterEntitlement() public {
        editions.setSupporter(alice, 0);
        vm.warp(initialClose);
        finalize();
        vm.prank(bob);
        editions.mintSupporter(SONG, alice);
        assertEq(editions.balanceOf(alice, SONG), 1);
        assertTrue(editions.editionSaleFinalized(SONG));
    }

    function testNewOwnerCanRevokeExistingRelayAndOldOwnerLosesImplicitAuthority() public {
        editions.transferOwnership(bob);
        vm.prank(bob);
        editions.acceptOwnership();
        vm.expectRevert(
            abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, address(this))
        );
        editions.extendEditionDeadline(SONG, initialClose + 1);
        assertTrue(editions.deadlineManagers(relay));
        vm.prank(bob);
        editions.setDeadlineManager(relay, false);
        vm.expectRevert(abi.encodeWithSelector(SongADayEditions.UnauthorizedDeadlineManager.selector, relay));
        extend(initialClose + 1);
        vm.prank(bob);
        editions.extendEditionDeadline(SONG, initialClose + 1);
    }

    function testFuzzMonotonicDeadlineAndPermanentFreeze(
        uint32[8] memory extensionSeeds,
        uint8 finalizationSeed
    ) public {
        uint256 expectedClose = initialClose;
        uint256 extensionCount = bound(uint256(finalizationSeed), 1, extensionSeeds.length);
        SongADayEditions.Edition memory original = editions.edition(SONG);
        for (uint256 i; i < extensionCount; ++i) {
            expectedClose += bound(uint256(extensionSeeds[i]), 1, 1 days);
            extend(expectedClose);
            assertEq(editions.edition(SONG).closesAt, expectedClose);
            vm.expectRevert(SongADayEditions.InvalidEditionDeadline.selector);
            extend(expectedClose);
        }
        vm.warp(expectedClose);
        finalize();
        for (uint256 i; i < extensionSeeds.length; ++i) {
            uint256 attemptedClose = expectedClose + bound(uint256(extensionSeeds[i]), 1, 1 days);
            vm.expectRevert(
                abi.encodeWithSelector(SongADayEditions.EditionSaleAlreadyFinalized.selector, SONG)
            );
            extend(attemptedClose);
        }
        SongADayEditions.Edition memory finalEdition = editions.edition(SONG);
        assertEq(finalEdition.closesAt, expectedClose);
        assertEq(finalEdition.price, original.price);
        assertEq(finalEdition.openedAt, original.openedAt);
        assertEq(finalEdition.supporterRevision, original.supporterRevision);
        assertEq(finalEdition.metadataURI, original.metadataURI);
        assertTrue(editions.editionSaleFinalized(SONG));
    }

    function testAuctionExtensionRelaysWithoutChangingSettlementOrEditionTerms() public {
        SongADayAuction auction = new SongADayAuction(address(this), editions.originalCollection(), bob);
        auction.createAuction(SONG, 0, uint64(initialClose), 100, 900, "ipfs://original");
        vm.warp(initialClose - 1);
        vm.prank(alice);
        auction.bid{value: 1}(SONG, 0, alice);
        uint256 firstExtendedClose = auction.getAuction(SONG).endTime;
        extend(firstExtendedClose);
        vm.warp(firstExtendedClose - 1);
        vm.prank(bob);
        auction.bid{value: 2}(SONG, 1, bob);
        uint256 finalClose = auction.getAuction(SONG).endTime;
        extend(finalClose);
        vm.prank(bob);
        editions.mintPaid{value: PRICE}(SONG);
        vm.warp(finalClose);
        auction.settle(SONG);
        finalize();
        assertEq(editions.edition(SONG).closesAt, auction.getAuction(SONG).endTime);
        assertTrue(auction.getAuction(SONG).settled);
        assertEq(auction.pendingWithdrawals(alice), 1);
        assertEq(auction.pendingWithdrawals(bob), 2);
        assertEq(editions.totalSupply(SONG), 1);
    }
}
