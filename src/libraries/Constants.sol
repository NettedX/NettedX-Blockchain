// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Constants {
    uint256 internal constant WINDOW_SIZE = 10;
    uint256 internal constant PREPARATION_BLOCKS = 2;
    uint256 internal constant SETTLEMENT_BLOCK_OFFSET = WINDOW_SIZE + PREPARATION_BLOCKS + 1;

    uint8 internal constant USDC_DECIMALS = 6;

    uint8 internal constant BOND_DECIMALS = 0;
}
