// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Events {
    event TradeSubmitted(
        uint256 indexed windowId,
        uint256 indexed tradeId,
        address indexed buyer,
        address seller,
        uint256 cashAmount,
        uint256 bondAmount
    );

    event WindowClosed(
        uint256 indexed windowId,
        uint256 tradeCount,
        uint256 startBlock,
        uint256 endBlock
    );

    event SettlementSucceeded(uint256 indexed windowId, uint256 transferCount);

    event SettlementReverted(uint256 indexed windowId, string reason);

    event Transferred(
        uint256 indexed windowId,
        address indexed asset,
        address from,
        address to,
        uint256 amount
    );
}
