// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../libraries/Types.sol";
import "../libraries/Constants.sol";
import "../libraries/Errors.sol";
import "../libraries/Events.sol";

import "../interfaces/ISettlement.sol";

contract Netting is Ownable {
    address public immutable cashToken;
    address public immutable bondToken;

    ISettlement public immutable settlement;

    uint256 public currentWindowId;
    uint256 public windowStartBlock;

    mapping(uint256 => Types.Trade[]) private trades;

    constructor(address initialOwner, address cashToken_, address bondToken_, address settlement_)
        Ownable(initialOwner)
    {
        if (cashToken_ == address(0) || bondToken_ == address(0) || settlement_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        cashToken = cashToken_;
        bondToken = bondToken_;
        settlement = ISettlement(settlement_);

        currentWindowId = 0;
        windowStartBlock = block.number;
    }

    /**
     * @notice Submit an already matched trade.
     *         No assets move here.
     */
    function submitTrade(address buyer, address seller, uint256 cashAmount, uint256 bondAmount) external {
        if (buyer == address(0) || seller == address(0)) {
            revert Errors.ZeroAddress();
        }

        if (buyer == seller) {
            revert Errors.InvalidTrade();
        }

        if (cashAmount == 0 || bondAmount == 0) {
            revert Errors.InvalidTrade();
        }

        // Current window is:
        //
        // [windowStartBlock, windowStartBlock + 9]
        //
        // Block 11 freezes the window. Blocks 12 and 13 are reserved
        // for funding preparation, and settlement starts at block 14.
        if (block.number < windowStartBlock || block.number >= windowStartBlock + Constants.WINDOW_SIZE) {
            revert Errors.WindowClosed();
        }

        Types.Trade memory trade = Types.Trade({
            buyer: buyer, seller: seller, cashAmount: cashAmount, bondAmount: bondAmount, blockNum: uint64(block.number)
        });

        uint256 tradeId = trades[currentWindowId].length;

        trades[currentWindowId].push(trade);

        emit Events.TradeSubmitted(currentWindowId, tradeId, buyer, seller, cashAmount, bondAmount);
    }

    /**
     * @notice Calculate the frozen window's net positions and atomically settle.
     *         Settlement is available from block 14 of the cycle.
     *
     *         Only operator / owner can call this.
     */
    function executeWindow() external onlyOwner {
        if (block.number < windowStartBlock + Constants.CYCLE_SIZE - 1) {
            revert Errors.SettlementNotReady();
        }

        uint256 windowId = currentWindowId;

        uint256 totalTrades = trades[windowId].length;

        if (totalTrades == 0) {
            emit Events.WindowClosed(windowId, 0, windowStartBlock, windowStartBlock + Constants.WINDOW_SIZE - 1);

            _advanceWindow();

            return;
        }

        emit Events.WindowClosed(windowId, totalTrades, windowStartBlock, windowStartBlock + Constants.WINDOW_SIZE - 1);

        Types.NetPosition[] memory positions = _calculateNetPositions(windowId);

        try settlement.settle(positions) {
            emit Events.SettlementSucceeded(windowId, _countTransfers(positions));

            delete trades[windowId];

            _advanceWindow();
        } catch Error(string memory reason) {
            emit Events.SettlementReverted(windowId, reason);

            _carryTradesToNextWindow(windowId);

            _advanceWindow();
        } catch (bytes memory) {
            emit Events.SettlementReverted(windowId, "settlement reverted");

            _carryTradesToNextWindow(windowId);

            _advanceWindow();
        }
    }

    /**
     * @notice Current window.
     */

    /**
     * @notice Blocks remaining before window closes.
     */
    function blocksRemaining() external view returns (uint256) {
        uint256 end = windowStartBlock + Constants.WINDOW_SIZE;

        if (block.number >= end) {
            return 0;
        }

        return end - block.number;
    }

    /**
     * @notice Preview current window net positions.
     */
    function previewNetPositions() external view returns (Types.NetPosition[] memory) {
        return _calculateNetPositions(currentWindowId);
    }

    function getPublicAnalyticsMetrics()
        external
        view
        returns (
            uint256 totalSettlementAmount,
            uint256 netSettlementCount,
            uint256 liquiditySaved,
            uint256 obligationReduction
        )
    {
        uint256 windowId = currentWindowId;

        Types.Trade[] storage windowTrades = trades[windowId];

        for (uint256 i = 0; i < windowTrades.length; i++) {
            totalSettlementAmount += windowTrades[i].cashAmount;
        }

        if (totalSettlementAmount == 0) {
            return (0, 0, 0, 0);
        }

        Types.NetPosition[] memory positions = _calculateNetPositions(windowId);

        uint256 netSettlementAmount;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].asset == cashToken && positions[i].amount < 0) {
                netSettlementAmount += uint256(-positions[i].amount);
                netSettlementCount++;
            }
        }

        liquiditySaved = totalSettlementAmount - netSettlementAmount;

        obligationReduction = (liquiditySaved * 100) / totalSettlementAmount;
    }

    /**
     * @notice Return trades count.
     */
    function tradeCount(uint256 windowId) external view returns (uint256) {
        return trades[windowId].length;
    }

    /**
     * @notice Return one trade.
     */
    function getTrade(uint256 windowId, uint256 tradeId) external view returns (Types.Trade memory) {
        return trades[windowId][tradeId];
    }

    /**
     * @dev Calculate net positions for current window.
     *
     * For every trade:
     *
     * buyer CASH  -= cash
     * seller CASH += cash
     *
     * buyer BOND  += bond
     * seller BOND -= bond
     */
    function _calculateNetPositions(uint256 windowId) internal view returns (Types.NetPosition[] memory) {
        Types.Trade[] storage windowTrades = trades[windowId];

        uint256 maxPositions = windowTrades.length * 4;

        Types.NetPosition[] memory temp = new Types.NetPosition[](maxPositions);

        uint256 count = 0;

        for (uint256 i = 0; i < windowTrades.length; i++) {
            Types.Trade storage trade = windowTrades[i];

            // Buyer pays CASH
            count = _addPosition(temp, count, trade.buyer, cashToken, -int256(trade.cashAmount));

            // Seller receives CASH
            count = _addPosition(temp, count, trade.seller, cashToken, int256(trade.cashAmount));

            // Buyer receives BOND
            count = _addPosition(temp, count, trade.buyer, bondToken, int256(trade.bondAmount));

            // Seller pays BOND
            count = _addPosition(temp, count, trade.seller, bondToken, -int256(trade.bondAmount));
        }

        Types.NetPosition[] memory result = new Types.NetPosition[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }

        _checkConservation(result);

        return result;
    }

    function _addPosition(
        Types.NetPosition[] memory positions,
        uint256 count,
        address participant,
        address asset,
        int256 delta
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < count; i++) {
            if (positions[i].participant == participant && positions[i].asset == asset) {
                positions[i].amount += delta;

                if (positions[i].amount == 0) {
                    // Keep zero entry for simplicity.
                }

                return count;
            }
        }

        positions[count] = Types.NetPosition({participant: participant, asset: asset, amount: delta});

        return count + 1;
    }

    /**
     * @dev Conservation law:
     *
     * sum(net[p][asset]) == 0
     */
    function _checkConservation(Types.NetPosition[] memory positions) internal pure {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amount == 0) {
                continue;
            }

            int256 total = positions[i].amount;

            for (uint256 j = i + 1; j < positions.length; j++) {
                if (positions[j].asset == positions[i].asset) {
                    total += positions[j].amount;
                }
            }

            // Only check once: i is the first occurrence.
            bool first = true;

            for (uint256 j = 0; j < i; j++) {
                if (positions[j].asset == positions[i].asset) {
                    first = false;
                    break;
                }
            }

            if (first && total != 0) {
                revert Errors.NetNotBalanced();
            }
        }
    }

    function _countTransfers(Types.NetPosition[] memory positions) internal pure returns (uint256 count) {
        // This is an upper-bound style estimate for event/UI.
        // Exact transfer count is determined inside Settlement.
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amount < 0) {
                count++;
            }
        }
    }

    function _carryTradesToNextWindow(uint256 windowId) internal {
        uint256 nextWindow = windowId + 1;

        uint256 length = trades[windowId].length;

        for (uint256 i = 0; i < length; i++) {
            trades[nextWindow].push(trades[windowId][i]);
        }

        delete trades[windowId];
    }

    function _advanceWindow() internal {
        currentWindowId += 1;

        windowStartBlock += Constants.CYCLE_SIZE;
    }
}
