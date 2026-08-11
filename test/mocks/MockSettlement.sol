// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { NetPosition } from "../../src/Types.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";

contract MockSettlement is ISettlement {
    using SafeERC20 for IERC20;

    address public netting;
    bool public shouldFail;
    uint256 public lastWindowId;
    uint256 public lastPositionCount;

    function setNetting(address netting_) external {
        require(netting == address(0), "netting already set");
        netting = netting_;
    }

    function setShouldFail(bool value) external {
        shouldFail = value;
    }

    function settle(uint256 windowId, NetPosition[] calldata positions) external {
        require(msg.sender == netting, "only netting");
        require(!shouldFail, "forced failure");

        uint256[] memory receivable = new uint256[](positions.length);
        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].amount > 0) receivable[i] = uint256(positions[i].amount);
        }

        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].amount >= 0) continue;
            uint256 remaining = uint256(-positions[i].amount);

            for (uint256 j; j < positions.length && remaining != 0; ++j) {
                if (positions[j].asset != positions[i].asset || receivable[j] == 0) continue;
                uint256 amount = remaining < receivable[j] ? remaining : receivable[j];
                IERC20(positions[i].asset)
                    .safeTransferFrom(positions[i].participant, positions[j].participant, amount);
                remaining -= amount;
                receivable[j] -= amount;
            }
            require(remaining == 0, "unbalanced positions");
        }

        lastWindowId = windowId;
        lastPositionCount = positions.length;
    }
}
