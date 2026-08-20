// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidityBuffer {
    /**
     * @notice Deposit ERC20 tokens into the liquidity buffer.
     */
    function deposit(address asset, uint256 amount) external;

    /**
     * @notice Withdraw deposited tokens.
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Provide liquidity to cover a participant's shortfall.
     *
     * The caller must be the authorized Settlement contract.
     */
    function provideLiquidity(address asset, address debtor, uint256 amount) external;

    /**
     * @notice Repay outstanding liquidity debt.
     */
    function repay(address asset, uint256 amount) external;

    /**
     * @notice Total available liquidity for an asset.
     */
    function liquidity(address asset) external view returns (uint256);

    /**
     * @notice Debt owed by a participant for an asset.
     */
    function debt(address debtor, address asset) external view returns (uint256);
}
