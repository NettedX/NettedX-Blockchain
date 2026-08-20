// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {LiquidityBuffer} from "../../src/core/LiquidityBuffer.sol";

contract LiquidityBufferTest is Test {
    MockUSDC usdc;
    LiquidityBuffer buffer;

    address alice = address(0x1);
    address bob = address(0x2);
    address settlement = address(0x3);

    function setUp() public {
        usdc = new MockUSDC(address(this));

        buffer = new LiquidityBuffer();

        buffer.setSettlement(settlement);

        usdc.mint(alice, 10_000 * 10 ** 6);
        usdc.mint(bob, 10_000 * 10 ** 6);

        vm.prank(alice);
        usdc.approve(address(buffer), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(buffer), type(uint256).max);
    }

    function testDeposit() public {
        uint256 amount = 1_000 * 10 ** 6;

        vm.prank(alice);
        buffer.deposit(address(usdc), amount);

        assertEq(buffer.liquidity(address(usdc)), amount);

        assertEq(buffer.deposits(alice, address(usdc)), amount);

        assertEq(usdc.balanceOf(address(buffer)), amount);
    }

    function testWithdraw() public {
        uint256 amount = 1_000 * 10 ** 6;

        vm.startPrank(alice);

        buffer.deposit(address(usdc), amount);

        buffer.withdraw(address(usdc), amount);

        vm.stopPrank();

        assertEq(buffer.liquidity(address(usdc)), 0);

        assertEq(buffer.deposits(alice, address(usdc)), 0);
    }

    function testOnlySettlementCanProvideLiquidity() public {
        uint256 amount = 1_000 * 10 ** 6;

        vm.prank(alice);

        buffer.deposit(address(usdc), amount);

        vm.prank(alice);

        vm.expectRevert("Only Settlement");

        buffer.provideLiquidity(address(usdc), bob, 100 * 10 ** 6);
    }

    function testProvideLiquidity() public {
        uint256 depositAmount = 1_000 * 10 ** 6;
        uint256 provideAmount = 200 * 10 ** 6;

        vm.prank(alice);

        buffer.deposit(address(usdc), depositAmount);

        vm.prank(settlement);

        buffer.provideLiquidity(address(usdc), bob, provideAmount);

        assertEq(buffer.liquidity(address(usdc)), depositAmount - provideAmount);

        assertEq(buffer.debt(bob, address(usdc)), provideAmount);

        assertEq(usdc.balanceOf(settlement), provideAmount);
    }

    function testRepay() public {
        uint256 depositAmount = 1_000 * 10 ** 6;
        uint256 provideAmount = 200 * 10 ** 6;

        vm.prank(alice);

        buffer.deposit(address(usdc), depositAmount);

        vm.prank(settlement);

        buffer.provideLiquidity(address(usdc), bob, provideAmount);

        vm.prank(bob);

        buffer.repay(address(usdc), provideAmount);

        assertEq(buffer.debt(bob, address(usdc)), 0);

        assertEq(buffer.liquidity(address(usdc)), depositAmount);

        assertEq(usdc.balanceOf(address(buffer)), depositAmount);
    }

    function testCannotProvideMoreThanLiquidity() public {
        uint256 depositAmount = 100 * 10 ** 6;
        uint256 provideAmount = 200 * 10 ** 6;

        vm.prank(alice);

        buffer.deposit(address(usdc), depositAmount);

        vm.prank(settlement);

        vm.expectRevert("Insufficient liquidity");

        buffer.provideLiquidity(address(usdc), bob, provideAmount);
    }

    function testCannotRepayMoreThanDebt() public {
        vm.prank(bob);

        vm.expectRevert("Repay exceeds debt");

        buffer.repay(address(usdc), 100 * 10 ** 6);
    }
}
