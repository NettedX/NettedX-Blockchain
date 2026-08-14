// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/Types.sol";

interface ISettlement {
    function settle(Types.NetPosition[] calldata positions) external;

    function checkShortfalls(
        Types.NetPosition[] calldata positions
    ) external view returns (Types.NetPosition[] memory);
}
