// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Types {
    struct Trade {
        address buyer;
        address seller;
        uint256 cashAmount;
        uint256 bondAmount;
        uint64 blockNum;
    }

    struct NetPosition {
        address participant;
        address asset;
        int256 amount;
    }
}
