// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A participant's net position in one ERC-20 asset.
/// @dev Positive means receivable; negative means payable.
struct NetPosition {
    address participant;
    address asset;
    int256 amount;
}
