// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

interface IExistingSongADay {
    function owner() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function dailyMint(uint256 tokenId, string calldata cid) external;
    function setFrequency(uint256 seconds_) external;
    function frequency() external view returns (uint256);
    function previousTreasuryMint() external view returns (uint256);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function approve(address spender, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Optional READ-ONLY remote fork; all impersonation and writes occur in the local EVM only.
contract ExistingOriginalForkTest is Test {
    IExistingSongADay internal constant ORIGINAL =
        IExistingSongADay(0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45);
    address internal constant TREASURY = 0x2a2C412c440Dfb0E7cae46EFF581e3E26aFd1Cd0;
    string internal constant CID = "bafkreib4jnstgdh7u3zxe3sgz7r6k62ze5cgaaj5po4wkvjrdclhefnxae";
    uint256 internal constant FORK_BLOCK = 26_222_849;
    uint256 internal constant SONG = 999_999_991;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function testForkActualDailyMintThenRereadOwnerAndDeliver() public {
        address operator = ORIGINAL.owner();
        vm.prank(operator);
        ORIGINAL.dailyMint(SONG, CID);
        address actualOwner = ORIGINAL.ownerOf(SONG);
        assertTrue(actualOwner == operator || actualOwner == TREASURY);
        assertEq(ORIGINAL.tokenURI(SONG), string.concat("ipfs://", CID));
        if (actualOwner != operator) {
            vm.prank(actualOwner);
            ORIGINAL.approve(operator, SONG);
        }
        address recipient = makeAddr("mainnet-recipient");
        vm.prank(operator);
        ORIGINAL.safeTransferFrom(actualOwner, recipient, SONG);
        assertEq(ORIGINAL.ownerOf(SONG), recipient);
    }

    function testForkActualTreasuryBranchRequiresDifferentTransferSource() public {
        address operator = ORIGINAL.owner();
        vm.prank(operator);
        ORIGINAL.setFrequency(0);
        uint256 timestamp = block.timestamp;
        while (uint256(keccak256(abi.encodePacked(timestamp, CID))) % 10 != 0) ++timestamp;
        vm.warp(timestamp);
        vm.prank(operator);
        ORIGINAL.dailyMint(SONG, CID);
        assertEq(ORIGINAL.ownerOf(SONG), TREASURY);
        assertNotEq(operator, TREASURY);
        vm.prank(operator);
        vm.expectRevert();
        ORIGINAL.safeTransferFrom(operator, makeAddr("recipient"), SONG);
        vm.prank(TREASURY);
        ORIGINAL.approve(operator, SONG);
        address actualOwner = ORIGINAL.ownerOf(SONG);
        vm.prank(operator);
        ORIGINAL.safeTransferFrom(actualOwner, makeAddr("recipient"), SONG);
        assertEq(ORIGINAL.ownerOf(SONG), makeAddr("recipient"));
    }

    function testForkMissingTokenRevertMatchesPlannerAcceptedReasons() public view {
        (bool ok, bytes memory reason) =
            address(ORIGINAL).staticcall(abi.encodeCall(ORIGINAL.ownerOf, (SONG)));
        assertFalse(ok);
        bytes32 digest = keccak256(reason);
        assertTrue(
            digest
                    == keccak256(
                        abi.encodeWithSignature("Error(string)", "ERC721: owner query for nonexistent token")
                    )
                || digest == keccak256(abi.encodeWithSignature("Error(string)", "ERC721: invalid token ID"))
                || digest == keccak256(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", SONG))
        );
    }
}
