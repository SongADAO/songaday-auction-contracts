// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {SongADayAuction} from "../src/SongADayAuction.sol";
import {SongADayEditions} from "../src/SongADayEditions.sol";

/// @dev Explicit CLI --broadcast is required for a transaction. No key is read from source or env.
contract DeployBaseAuction is Script {
    address internal constant ORIGINAL = 0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45;

    function run() external returns (SongADayAuction deployed) {
        require(block.chainid == 8453 || block.chainid == 84532, "Base or Base Sepolia required");
        address initialOwner = vm.envAddress("AUCTION_OWNER");
        address beneficiary = vm.envAddress("AUCTION_BENEFICIARY");
        vm.startBroadcast();
        deployed = new SongADayAuction(initialOwner, ORIGINAL, beneficiary);
        vm.stopBroadcast();
    }
}

contract DeployMainnetEditions is Script {
    address internal constant ORIGINAL = 0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45;

    function run() external returns (SongADayEditions deployed) {
        require(block.chainid == 1, "Ethereum mainnet required; use local test mocks for rehearsal");
        address initialOwner = vm.envAddress("EDITION_OWNER");
        address paymentToken = vm.envAddress("EDITION_PAYMENT_TOKEN");
        vm.startBroadcast();
        deployed = new SongADayEditions(initialOwner, ORIGINAL, paymentToken);
        vm.stopBroadcast();
    }
}
