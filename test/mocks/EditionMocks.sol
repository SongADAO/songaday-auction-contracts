// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {SongADayEditions} from "../../src/SongADayEditions.sol";

contract EditionOriginal {}

contract EditionToken is ERC20 {
    constructor() ERC20("Test Dollar", "USD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract EditionFalseToken is EditionToken {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract EditionFeeToken is EditionToken {
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract EditionReentrantToken is EditionToken {
    SongADayEditions public target;
    uint256 public songId;
    bool public reentrySucceeded;

    function configure(SongADayEditions target_, uint256 songId_) external {
        target = target_;
        songId = songId_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        (reentrySucceeded,) = address(target).call(abi.encodeCall(target.mintPaid, (songId)));
        return super.transferFrom(from, to, value);
    }
}

contract EditionRejectingReceiver is ERC1155Holder {
    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert("Edition rejected");
    }
}

contract EditionGasBurningReceiver is ERC1155Holder {
    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        pure
        override
        returns (bytes4 result)
    {
        assembly { for {} 1 {} {} }
    }
}

contract EditionReturnBombReceiver is ERC1155Holder {
    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        assembly { revert(0, 500000) }
    }
}

contract EditionReentrantReceiver is ERC1155Holder {
    address public target;
    bytes public payload;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    function configure(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
    }

    function buy(SongADayEditions editions, uint256 songId) external payable {
        editions.mintPaid{value: msg.value}(songId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        bytes memory returned;
        (reentrySucceeded, returned) = target.call(payload);
        if (returned.length >= 4) reentryError = bytes4(returned);
        return IERC1155Receiver.onERC1155Received.selector;
    }
}

contract EditionExpensiveReceiver is ERC1155Holder {
    uint256[12] public values;

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        for (uint256 i; i < values.length; ++i) {
            values[i] = i + 1;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function buy(SongADayEditions editions, uint256 songId) external payable {
        editions.mintPaid{value: msg.value}(songId);
    }
}

contract EditionRejectingBuyer is EditionRejectingReceiver {
    function buy(SongADayEditions editions, uint256 songId) external payable {
        editions.mintPaid{value: msg.value}(songId);
    }

    function buyWithToken(SongADayEditions editions, EditionToken token, uint256 songId, uint256 amount)
        external
    {
        token.approve(address(editions), amount);
        editions.mintPaid(songId);
    }
}
