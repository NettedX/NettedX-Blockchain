// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {MockBond} from "../../src/tokens/MockBond.sol";

import {Settlement} from "../../src/core/Settlement.sol";
import {Netting} from "../../src/core/Netting.sol";
import {LiquidityPool} from "../../src/core/LiquidityPool.sol";

import {Types} from "../../src/libraries/Types.sol";

contract SettlementTest is Test {
    MockUSDC usdc;
    MockBond bond;

    Settlement settlement;
    Netting netting;
    LiquidityPool liquidityPool;

    address alice;
    address bob;
    address liquidityProvider;

    uint256 constant USDC = 1_000_000;

    function setUp() public {
        // =========================================================
        // Accounts
        // =========================================================

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        liquidityProvider = makeAddr("liquidityProvider");

        // =========================================================
        // Deploy Tokens
        // =========================================================

        usdc = new MockUSDC(address(this));
        bond = new MockBond(address(this));

        // =========================================================
        // Deploy Settlement
        // =========================================================

        settlement = new Settlement();

        // =========================================================
        // Deploy LiquidityPool
        // =========================================================

        liquidityPool = new LiquidityPool();

        // =========================================================
        // Deploy Netting
        // =========================================================

        netting = new Netting(address(this), address(usdc), address(bond), address(settlement));

        // =========================================================
        // Two-phase initialization
        // =========================================================

        // Settlement -> Netting
        settlement.setNetting(address(netting));

        // Settlement -> LiquidityPool
        settlement.setLiquidityPool(address(liquidityPool));

        // LiquidityPool -> Settlement
        liquidityPool.setSettlement(address(settlement));

        // =========================================================
        // Initial balances
        // =========================================================

        // Alice: 1000 USDC
        usdc.mint(alice, 1_000 * USDC);

        // Bob: 10 BOND
        bond.mint(bob, 10);

        // =========================================================
        // Settlement allowances
        // =========================================================

        vm.prank(alice);

        usdc.approve(address(settlement), type(uint256).max);

        vm.prank(bob);

        bond.approve(address(settlement), type(uint256).max);
    }

    // ============================================================
    // 1. Initial State
    // ============================================================

    function testInitialState() public view {
        assertEq(settlement.netting(), address(netting));

        assertEq(settlement.liquidityPool(), address(liquidityPool));

        assertEq(liquidityPool.settlement(), address(settlement));
    }

    // ============================================================
    // 2. Normal Settlement Through Netting
    // ============================================================

    function testSettlementThroughNetting() public {
        // Alice buys 5 BOND from Bob.
        //
        // Alice:
        //   -500 USDC
        //   +5 BOND
        //
        // Bob:
        //   +500 USDC
        //   -5 BOND

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        // Close current window.
        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);
        vm.roll(netting.windowStartBlock() + 13);

        // Netting -> Settlement
        netting.executeWindow();

        // Alice
        assertEq(usdc.balanceOf(alice), 500 * USDC);

        assertEq(bond.balanceOf(alice), 5);

        // Bob
        assertEq(usdc.balanceOf(bob), 500 * USDC);

        assertEq(bond.balanceOf(bob), 5);
    }

    // ============================================================
    // 3. Settlement Cannot Be Called Directly
    // ============================================================

    function testSettlementCannotBeCalledDirectly() public {
        Types.NetPosition[] memory positions = new Types.NetPosition[](2);

        positions[0] = Types.NetPosition({participant: alice, asset: address(usdc), amount: -int256(100 * USDC)});

        positions[1] = Types.NetPosition({participant: bob, asset: address(usdc), amount: int256(100 * USDC)});

        // This test contract is NOT Netting.
        //
        // Therefore Settlement.settle()
        // must revert with OnlyNetting.

        vm.expectRevert();

        settlement.settle(positions);
    }

    // ============================================================
    // 4. LiquidityPool Configuration
    // ============================================================

    function testLiquidityPoolConfigured() public view {
        assertEq(settlement.liquidityPool(), address(liquidityPool));

        assertEq(liquidityPool.settlement(), address(settlement));
    }

    // ============================================================
    // 5. Netting Configuration
    // ============================================================

    function testNettingConfigured() public view {
        assertEq(settlement.netting(), address(netting));
    }

    // ============================================================
    // 6. Liquidity Pool Covers Shortfall
    // ============================================================

    function testSettlementWithLiquidityPool() public {
        // ========================================================
        // Alice only has 100 USDC.
        //
        // Initially:
        // Alice = 1000 USDC
        //
        // Remove 900:
        // Alice = 100 USDC
        // ========================================================

        vm.prank(alice);

        usdc.transfer(address(0xdead), 900 * USDC);

        assertEq(usdc.balanceOf(alice), 100 * USDC);

        // ========================================================
        // Liquidity Provider deposits 500 USDC
        // ========================================================

        usdc.mint(liquidityProvider, 500 * USDC);

        vm.prank(liquidityProvider);

        usdc.approve(address(liquidityPool), type(uint256).max);

        vm.prank(liquidityProvider);

        liquidityPool.deposit(address(usdc), 500 * USDC);

        assertEq(liquidityPool.liquidity(address(usdc)), 500 * USDC);

        // ========================================================
        // Submit trade
        // ========================================================

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        // ========================================================
        // Close window
        // ========================================================

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);
        vm.roll(netting.windowStartBlock() + 13);

        // ========================================================
        // Execute settlement
        // ========================================================

        netting.executeWindow();

        // ========================================================
        // Alice paid 100 USDC.
        // Pool paid remaining 400 USDC.
        // ========================================================

        assertEq(usdc.balanceOf(alice), 0);

        // Bob receives the complete 500 USDC.

        assertEq(usdc.balanceOf(bob), 500 * USDC);

        // ========================================================
        // Alice now owes Pool 400 USDC.
        // ========================================================

        assertEq(liquidityPool.debt(alice, address(usdc)), 400 * USDC);

        // ========================================================
        // Pool liquidity decreased from 500 -> 100.
        // ========================================================

        assertEq(liquidityPool.liquidity(address(usdc)), 100 * USDC);

        // ========================================================
        // Bob should still receive 5 BOND.
        // ========================================================

        assertEq(bond.balanceOf(alice), 5);

        assertEq(bond.balanceOf(bob), 5);
    }

    // ============================================================
    // 7. Liquidity Pool Debt Repayment
    // ============================================================

    function testLiquidityPoolRepayment() public {
        // ========================================================
        // Alice only has 100 USDC.
        // ========================================================

        vm.prank(alice);

        usdc.transfer(address(0xdead), 900 * USDC);

        assertEq(usdc.balanceOf(alice), 100 * USDC);

        // ========================================================
        // Liquidity Provider deposits 500 USDC.
        // ========================================================

        usdc.mint(liquidityProvider, 500 * USDC);

        vm.prank(liquidityProvider);

        usdc.approve(address(liquidityPool), type(uint256).max);

        vm.prank(liquidityProvider);

        liquidityPool.deposit(address(usdc), 500 * USDC);

        // ========================================================
        // Submit trade.
        // ========================================================

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        // ========================================================
        // Close window.
        // ========================================================

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);
        vm.roll(netting.windowStartBlock() + 13);

        // ========================================================
        // Execute settlement.
        // ========================================================

        netting.executeWindow();

        // ========================================================
        // Alice owes 400 USDC.
        // ========================================================

        assertEq(liquidityPool.debt(alice, address(usdc)), 400 * USDC);

        // Pool currently has 100 USDC left.
        assertEq(liquidityPool.liquidity(address(usdc)), 100 * USDC);

        // ========================================================
        // Alice gets 400 USDC later.
        //
        // This represents Alice replenishing her funds.
        // ========================================================

        usdc.mint(alice, 400 * USDC);

        assertEq(usdc.balanceOf(alice), 400 * USDC);

        // ========================================================
        // Alice approves LiquidityPool.
        // ========================================================

        vm.prank(alice);

        usdc.approve(address(liquidityPool), 400 * USDC);

        // ========================================================
        // Alice repays debt.
        // ========================================================

        vm.prank(alice);

        liquidityPool.repay(address(usdc), 400 * USDC);

        // ========================================================
        // Debt becomes zero.
        // ========================================================

        assertEq(liquidityPool.debt(alice, address(usdc)), 0);

        // ========================================================
        // Pool liquidity returns to 500 USDC.
        // ========================================================

        assertEq(liquidityPool.liquidity(address(usdc)), 500 * USDC);

        // ========================================================
        // Alice has no remaining USDC.
        // ========================================================

        assertEq(usdc.balanceOf(alice), 0);
    }
}
