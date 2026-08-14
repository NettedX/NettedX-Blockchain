// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {LiquidityPool} from "../../src/core/LiquidityPool.sol";

contract LiquidityPoolTest is Test {
    MockUSDC usdc;
    LiquidityPool pool;

    address alice = address(0x1);
    address bob = address(0x2);
    address settlement = address(0x3);

    function setUp() public {
        usdc = new MockUSDC(address(this));

        pool = new LiquidityPool();

        pool.setSettlement(settlement);

        usdc.mint(alice, 10_000 * 10 ** 6);
        usdc.mint(bob, 10_000 * 10 ** 6);

        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
    }

    function testDeposit() public {
        uint256 amount = 1_000 * 10 ** 6;

        vm.prank(alice);
        pool.deposit(address(usdc), amount);

        assertEq(pool.liquidity(address(usdc)), amount);

        assertEq(pool.deposits(alice, address(usdc)), amount);

        assertEq(usdc.balanceOf(address(pool)), amount);
    }

    function testWithdraw() public {
        uint256 amount = 1_000 * 10 ** 6;

        vm.startPrank(alice);

        pool.deposit(address(usdc), amount);

        pool.withdraw(address(usdc), amount);

        vm.stopPrank();

        assertEq(pool.liquidity(address(usdc)), 0);

        assertEq(pool.deposits(alice, address(usdc)), 0);
    }

    function testOnlySettlementCanProvideLiquidity() public {
        uint256 amount = 1_000 * 10 ** 6;

        vm.prank(alice);

        pool.deposit(address(usdc), amount);

        vm.prank(alice);

        vm.expectRevert("Only Settlement");

        pool.provideLiquidity(address(usdc), bob, 100 * 10 ** 6);
    }

    function testProvideLiquidity() public {
        uint256 depositAmount = 1_000 * 10 ** 6;
        uint256 provideAmount = 200 * 10 ** 6;

        vm.prank(alice);

        pool.deposit(address(usdc), depositAmount);

        vm.prank(settlement);

        pool.provideLiquidity(address(usdc), bob, provideAmount);

        assertEq(pool.liquidity(address(usdc)), depositAmount - provideAmount);

        assertEq(pool.debt(bob, address(usdc)), provideAmount);

        assertEq(usdc.balanceOf(settlement), provideAmount);
    }

    function testRepay() public {
        uint256 depositAmount = 1_000 * 10 ** 6;
        uint256 provideAmount = 200 * 10 ** 6;

        vm.prank(alice);

        pool.deposit(address(usdc), depositAmount);

        vm.prank(settlement);

        pool.provideLiquidity(address(usdc), bob, provideAmount);

        vm.prank(bob);

        pool.repay(address(usdc), provideAmount);

        assertEq(pool.debt(bob, address(usdc)), 0);

        assertEq(pool.liquidity(address(usdc)), depositAmount);

        assertEq(usdc.balanceOf(address(pool)), depositAmount);
    }

    function testCannotProvideMoreThanLiquidity() public {
        uint256 depositAmount = 100 * 10 ** 6;
        uint256 provideAmount = 200 * 10 ** 6;

        vm.prank(alice);

        pool.deposit(address(usdc), depositAmount);

        vm.prank(settlement);

        vm.expectRevert("Insufficient liquidity");

        pool.provideLiquidity(address(usdc), bob, provideAmount);
    }

    function testCannotRepayMoreThanDebt() public {
        vm.prank(bob);

        vm.expectRevert("Repay exceeds debt");

        pool.repay(address(usdc), 100 * 10 ** 6);
    }
}
