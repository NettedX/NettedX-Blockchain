// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/INetting.sol";
import "../interfaces/ISettlement.sol";
import "../interfaces/ILiquidityBuffer.sol";

import "../libraries/Types.sol";
import "../libraries/Errors.sol";
import "../libraries/Events.sol";

contract Settlement is ISettlement, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // =============================================================
    // State
    // =============================================================

    /**
     * @notice Netting contract address.
     *
     * Netting is configured after deployment.
     */
    address public netting;

    /**
     * @notice Liquidity Buffer contract address.
     *
     * LiquidityBuffer is configured after deployment.
     */
    address public liquidityBuffer;

    // =============================================================
    // Constructor
    // =============================================================

    constructor() Ownable(msg.sender) {}

    // =============================================================
    // Initialization
    // =============================================================

    /**
     * @notice Set Netting contract address.
     * @dev Can only be called once by the owner.
     */
    function setNetting(address netting_) external onlyOwner {
        if (netting != address(0)) {
            revert Errors.OnlyNetting();
        }

        if (netting_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        netting = netting_;
    }

    /**
     * @notice Set Liquidity Buffer contract address.
     * @dev Can only be called once by the owner.
     */
    function setLiquidityBuffer(address liquidityBuffer_) external onlyOwner {
        if (liquidityBuffer != address(0)) {
            revert Errors.LiquidityBufferAlreadySet();
        }

        if (liquidityBuffer_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        liquidityBuffer = liquidityBuffer_;
    }

    // =============================================================
    // Modifiers
    // =============================================================

    /**
     * @dev Only Netting can call settlement.
     */
    modifier onlyNetting() {
        if (msg.sender != netting) {
            revert Errors.OnlyNetting();
        }

        _;
    }

    // =============================================================
    // Settlement
    // =============================================================

    /**
     * @notice Execute all net transfers atomically.
     *
     * Normal case:
     *
     *     Payer has enough balance
     *             ↓
     *     Payer -> Receiver
     *
     * Liquidity shortage:
     *
     *     Payer has insufficient balance
     *             ↓
     *     Payer pays what they have
     *             ↓
     *     LiquidityBuffer provides shortfall
     *             ↓
     *     Settlement -> Receiver
     *
     * The LiquidityBuffer records the shortfall as debt.
     */
    function settle(Types.NetPosition[] calldata positions) external override onlyNetting nonReentrant {
        if (positions.length == 0) {
            revert Errors.InvalidPosition();
        }

        if (liquidityBuffer == address(0)) {
            revert Errors.LiquidityBufferNotSet();
        }

        uint256 transferCount = 0;

        Types.NetPosition[] memory remaining = new Types.NetPosition[](positions.length);

        for (uint256 i = 0; i < positions.length; i++) {
            remaining[i] = positions[i];
        }

        // =========================================================
        // Match negative positions with positive positions
        // for the same asset.
        // =========================================================

        for (uint256 i = 0; i < remaining.length; i++) {
            if (remaining[i].amount >= 0) {
                continue;
            }

            address asset = remaining[i].asset;
            address payer = remaining[i].participant;

            uint256 amountToPay = uint256(-remaining[i].amount);

            for (uint256 j = 0; j < remaining.length; j++) {
                if (remaining[j].amount <= 0) {
                    continue;
                }

                if (remaining[j].asset != asset) {
                    continue;
                }

                uint256 amountToReceive = uint256(remaining[j].amount);

                uint256 amount = amountToPay < amountToReceive ? amountToPay : amountToReceive;

                if (amount == 0) {
                    continue;
                }

                address receiver = remaining[j].participant;

                IERC20 token = IERC20(asset);

                // =================================================
                // Check allowance
                //
                // The user must authorize Settlement to spend
                // the amount that they are responsible for.
                // =================================================

                uint256 allowance = token.allowance(payer, address(this));

                if (allowance == 0) {
                    revert Errors.InsufficientAllowance();
                }

                // =================================================
                // Determine how much payer can actually pay.
                // =================================================

                uint256 balance = token.balanceOf(payer);

                uint256 payerAmount = balance < amount ? balance : amount;

                // =================================================
                // Liquidity Buffer covers the shortfall.
                // =================================================

                uint256 bufferAmount = amount - payerAmount;

                if (bufferAmount > 0) {
                    ILiquidityBuffer(liquidityBuffer).provideLiquidity(asset, payer, bufferAmount);
                }

                // =================================================
                // Payer pays their available amount.
                // =================================================

                if (payerAmount > 0) {
                    if (allowance < payerAmount) {
                        revert Errors.InsufficientAllowance();
                    }

                    token.safeTransferFrom(payer, receiver, payerAmount);
                }

                // =================================================
                // LiquidityBuffer funds are now sitting in Settlement.
                //
                // Send them to receiver.
                // =================================================

                if (bufferAmount > 0) {
                    token.safeTransfer(receiver, bufferAmount);
                }

                emit Events.Transferred(INetting(netting).currentWindowId(), asset, payer, receiver, amount);

                transferCount++;

                amountToPay -= amount;

                remaining[j].amount -= int256(amount);

                if (amountToPay == 0) {
                    break;
                }
            }

            if (amountToPay != 0) {
                revert Errors.NetNotBalanced();
            }

            remaining[i].amount = 0;
        }

        // =========================================================
        // All positions must be fully matched.
        // =========================================================

        for (uint256 i = 0; i < remaining.length; i++) {
            if (remaining[i].amount != 0) {
                revert Errors.NetNotBalanced();
            }
        }

        if (transferCount == 0) {
            revert Errors.InvalidPosition();
        }
    }

    // =============================================================
    // Shortfall Check
    // =============================================================

    /**
     * @notice Check which participants have
     *         insufficient balance or allowance.
     */
    function checkShortfalls(Types.NetPosition[] calldata positions)
        external
        view
        override
        returns (Types.NetPosition[] memory)
    {
        uint256 count = 0;

        // First pass: count shortfalls.
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amount >= 0) {
                continue;
            }

            uint256 required = uint256(-positions[i].amount);

            IERC20 token = IERC20(positions[i].asset);

            if (
                token.balanceOf(positions[i].participant) < required
                    || token.allowance(positions[i].participant, address(this)) < required
            ) {
                count++;
            }
        }

        Types.NetPosition[] memory result = new Types.NetPosition[](count);

        uint256 index = 0;

        // Second pass: fill result.
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amount >= 0) {
                continue;
            }

            uint256 required = uint256(-positions[i].amount);

            IERC20 token = IERC20(positions[i].asset);

            bool shortfall = token.balanceOf(positions[i].participant) < required
                || token.allowance(positions[i].participant, address(this)) < required;

            if (shortfall) {
                result[index] = positions[i];
                index++;
            }
        }

        return result;
    }
}
