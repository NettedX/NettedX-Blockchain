// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
    mapping(uint256 => bool) public windowFrozen;

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

        // The current settlement window is:
        //
        // [windowStartBlock, windowStartBlock + 9]
        //
        // From block 11, new trades belong to the next window while
        // the current one is frozen, prepared and settled in parallel.
        uint256 targetWindow = tradingWindowId();

        Types.Trade memory trade = Types.Trade({
            buyer: buyer, seller: seller, cashAmount: cashAmount, bondAmount: bondAmount, blockNum: uint64(block.number)
        });

        uint256 tradeId = trades[targetWindow].length;

        trades[targetWindow].push(trade);

        emit Events.TradeSubmitted(targetWindow, tradeId, buyer, seller, cashAmount, bondAmount);
    }

    /**
     * @notice Freeze the current window from block 11.
     *         The next window is already open for trade submission.
     */
    function freezeWindow() external onlyOwner {
        _freezeWindow(currentWindowId);
    }

    /**
     * @notice Calculate the frozen window's net positions and atomically settle.
     *         Settlement is available from block 14 of the cycle.
     *
     *         Only operator / owner can call this.
     */
    function executeWindow() external onlyOwner {
        if (block.number < windowStartBlock + Constants.SETTLEMENT_BLOCK_OFFSET) {
            revert Errors.SettlementNotReady();
        }

        uint256 windowId = currentWindowId;

        _freezeWindow(windowId);

        uint256 totalTrades = trades[windowId].length;

        if (totalTrades == 0) {
            _advanceWindow();

            return;
        }

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
     * @notice Window currently accepting trades.
     */
    function tradingWindowId() public view returns (uint256) {
        if (block.number >= windowStartBlock + Constants.WINDOW_SIZE * 2) {
            revert Errors.WindowBacklog();
        }

        if (block.number >= windowStartBlock + Constants.WINDOW_SIZE) {
            return currentWindowId + 1;
        }

        return currentWindowId;
    }

    /**
     * @notice Actions that the automatic operator should execute now.
     */
    function automationState() external view returns (bool freezeNeeded, bool settlementNeeded) {
        freezeNeeded = block.number >= windowStartBlock + Constants.WINDOW_SIZE && !windowFrozen[currentWindowId];
        settlementNeeded = block.number >= windowStartBlock + Constants.SETTLEMENT_BLOCK_OFFSET;
    }

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

    /**
     * @notice Forecast the next settlement using block numbers only.
     */
    function getSettlementWindowForecast() external view returns (Types.SettlementWindowForecast memory forecast) {
        forecast.windowId = currentWindowId;
        forecast.settlementBlock = windowStartBlock + Constants.SETTLEMENT_BLOCK_OFFSET;
        forecast.blocksRemaining =
            block.number >= forecast.settlementBlock ? 0 : forecast.settlementBlock - block.number;
    }

    /**
     * @notice Return the selected bank's payable and receivable amounts by asset.
     */
    function getBankNetPositions(address bank) external view returns (Types.BankNetPosition[] memory) {
        return _getBankNetPositions(bank);
    }

    /**
     * @notice Return the assets and amounts the selected bank must provide for settlement.
     */
    function getBankSettlementAssetRequirements(address bank)
        external
        view
        returns (Types.SettlementAssetRequirement[] memory requirements)
    {
        Types.BankNetPosition[] memory bankPositions = _getBankNetPositions(bank);
        uint256 count;

        for (uint256 i = 0; i < bankPositions.length; i++) {
            if (bankPositions[i].payableAmount > 0) {
                count++;
            }
        }

        requirements = new Types.SettlementAssetRequirement[](count);
        uint256 index;

        for (uint256 i = 0; i < bankPositions.length; i++) {
            if (bankPositions[i].payableAmount == 0) {
                continue;
            }

            requirements[index] = Types.SettlementAssetRequirement({
                asset: bankPositions[i].asset, requiredAmount: bankPositions[i].payableAmount
            });
            index++;
        }
    }

    /**
     * @notice Estimate how much the selected bank must borrow for each required asset.
     */
    function getBankLiquidityShortfalls(address bank)
        external
        view
        returns (Types.LiquidityShortfall[] memory shortfalls)
    {
        Types.BankNetPosition[] memory bankPositions = _getBankNetPositions(bank);
        uint256 count;

        for (uint256 i = 0; i < bankPositions.length; i++) {
            if (bankPositions[i].payableAmount > 0) {
                count++;
            }
        }

        shortfalls = new Types.LiquidityShortfall[](count);
        uint256 index;

        for (uint256 i = 0; i < bankPositions.length; i++) {
            uint256 requiredAmount = bankPositions[i].payableAmount;

            if (requiredAmount == 0) {
                continue;
            }

            uint256 availableBalance = IERC20(bankPositions[i].asset).balanceOf(bank);
            uint256 borrowAmount = availableBalance >= requiredAmount ? 0 : requiredAmount - availableBalance;

            shortfalls[index] = Types.LiquidityShortfall({
                asset: bankPositions[i].asset,
                requiredAmount: requiredAmount,
                availableBalance: availableBalance,
                borrowAmount: borrowAmount
            });
            index++;
        }
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

    function _getBankNetPositions(address bank) internal view returns (Types.BankNetPosition[] memory result) {
        if (bank == address(0)) {
            revert Errors.ZeroAddress();
        }

        Types.NetPosition[] memory positions = _calculateNetPositions(currentWindowId);
        uint256 count;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].participant == bank && positions[i].amount != 0) {
                count++;
            }
        }

        result = new Types.BankNetPosition[](count);
        uint256 index;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].participant != bank || positions[i].amount == 0) {
                continue;
            }

            int256 amount = positions[i].amount;

            result[index] = Types.BankNetPosition({
                asset: positions[i].asset,
                payableAmount: amount < 0 ? SafeCast.toUint256(-amount) : 0,
                receivableAmount: amount > 0 ? SafeCast.toUint256(amount) : 0
            });
            index++;
        }
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

    function _freezeWindow(uint256 windowId) internal {
        if (windowFrozen[windowId]) {
            return;
        }

        if (block.number < windowStartBlock + Constants.WINDOW_SIZE) {
            revert Errors.WindowNotClosed();
        }

        windowFrozen[windowId] = true;

        emit Events.WindowClosed(
            windowId, trades[windowId].length, windowStartBlock, windowStartBlock + Constants.WINDOW_SIZE - 1
        );
    }

    function _advanceWindow() internal {
        currentWindowId += 1;

        windowStartBlock += Constants.WINDOW_SIZE;
    }
}
