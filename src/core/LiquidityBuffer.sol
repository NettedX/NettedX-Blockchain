// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/ILiquidityBuffer.sol";

contract LiquidityBuffer is ILiquidityBuffer, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @notice Authorized Settlement contract.
     */
    address public settlement;

    /**
     * @notice Total liquidity available for each asset.
     *
     * Example:
     * liquidity[USDC] = 10000 USDC
     */
    mapping(address => uint256) public override liquidity;

    /**
     * @notice Amount deposited by each liquidity provider.
     *
     * provider => asset => amount
     */
    mapping(address => mapping(address => uint256)) public deposits;

    /**
     * @notice Outstanding debt.
     *
     * debtor => asset => amount
     */
    mapping(address => mapping(address => uint256)) public override debt;

    /**
     * @notice Create LiquidityBuffer.
     *
     * Settlement is configured separately because
     * LiquidityBuffer and Settlement may have deployment
     * dependencies.
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Set Settlement contract.
     *
     * Can only be configured once.
     */
    function setSettlement(address settlement_) external onlyOwner {
        require(settlement == address(0), "Settlement already set");

        require(settlement_ != address(0), "Zero settlement");

        settlement = settlement_;
    }

    /**
     * @notice Only Settlement can provide liquidity.
     */
    modifier onlySettlement() {
        require(msg.sender == settlement, "Only Settlement");
        _;
    }

    /**
     * @notice Deposit tokens into the buffer.
     */
    function deposit(address asset, uint256 amount) external override nonReentrant {
        require(asset != address(0), "Zero asset");

        require(amount > 0, "Zero amount");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        deposits[msg.sender][asset] += amount;
        liquidity[asset] += amount;
    }

    /**
     * @notice Withdraw previously deposited tokens.
     *
     * Liquidity providers can only withdraw their
     * own deposited funds.
     */
    function withdraw(address asset, uint256 amount) external override nonReentrant {
        require(asset != address(0), "Zero asset");

        require(amount > 0, "Zero amount");

        require(deposits[msg.sender][asset] >= amount, "Insufficient deposit");

        require(liquidity[asset] >= amount, "Insufficient liquidity");

        deposits[msg.sender][asset] -= amount;
        liquidity[asset] -= amount;

        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Provide liquidity for a participant.
     *
     * This function does NOT transfer tokens to the debtor.
     *
     * It transfers the required amount directly from the
     * LiquidityBuffer to Settlement.
     *
     * Settlement can then use those funds to complete
     * the settlement process.
     */
    function provideLiquidity(address asset, address debtor, uint256 amount)
        external
        override
        onlySettlement
        nonReentrant
    {
        require(asset != address(0), "Zero asset");

        require(debtor != address(0), "Zero debtor");

        require(amount > 0, "Zero amount");

        require(liquidity[asset] >= amount, "Insufficient liquidity");

        liquidity[asset] -= amount;

        debt[debtor][asset] += amount;

        IERC20(asset).safeTransfer(settlement, amount);
    }

    /**
     * @notice Repay outstanding liquidity debt.
     */
    function repay(address asset, uint256 amount) external override nonReentrant {
        require(asset != address(0), "Zero asset");

        require(amount > 0, "Zero amount");

        require(debt[msg.sender][asset] >= amount, "Repay exceeds debt");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        debt[msg.sender][asset] -= amount;
        liquidity[asset] += amount;
    }
}
