// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INetting {
    function currentWindowId() external view returns (uint256);

    function windowStartBlock() external view returns (uint256);
}
