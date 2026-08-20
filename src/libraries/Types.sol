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

    struct SettlementWindowForecast {
        uint256 windowId;
        uint256 settlementBlock;
        uint256 blocksRemaining;
    }

    struct BankNetPosition {
        address asset;
        uint256 payableAmount;
        uint256 receivableAmount;
    }

    struct SettlementAssetRequirement {
        address asset;
        uint256 requiredAmount;
    }

    struct LiquidityShortfall {
        address asset;
        uint256 requiredAmount;
        uint256 availableBalance;
        uint256 borrowAmount;
    }
}
