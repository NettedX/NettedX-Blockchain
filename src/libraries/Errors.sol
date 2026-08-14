// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    error ZeroAddress();
    error InvalidTrade();

    error WindowNotClosed();
    error WindowClosed();
    error SettlementNotReady();
    error EmptyWindow();

    error NotOperator();

    error OnlyNetting();

    error InvalidPosition();
    error NetNotBalanced();

    error InsufficientBalance();
    error InsufficientAllowance();

    error InvalidAsset();
    error LiquidityPoolAlreadySet();
    error LiquidityPoolNotSet();
}
