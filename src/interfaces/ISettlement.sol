// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { NetPosition } from "../Types.sol";

/// @notice Execution boundary used by Netting after a window becomes feasible.
interface ISettlement {
    /// @dev Must atomically settle every supplied position or revert.
    function settle(uint256 windowId, NetPosition[] calldata positions) external;
}
