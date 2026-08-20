// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {MockBond} from "../../src/tokens/MockBond.sol";

import {Settlement} from "../../src/core/Settlement.sol";
import {Netting} from "../../src/core/Netting.sol";
import {LiquidityBuffer} from "../../src/core/LiquidityBuffer.sol";

contract EndToEndTest is Test {
    MockUSDC usdc;
    MockBond bond;

    Settlement settlement;
    Netting netting;
    LiquidityBuffer liquidityBuffer;

    address alice;
    address bob;
    address liquidityProvider;

    uint256 constant USDC = 1_000_000;

    function setUp() public {
        // ==================================================
        // 1. Accounts
        // ==================================================

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        liquidityProvider = makeAddr("liquidityProvider");

        // ==================================================
        // 2. Deploy Tokens
        // ==================================================

        usdc = new MockUSDC(address(this));
        bond = new MockBond(address(this));

        // ==================================================
        // 3. Deploy Settlement
        // ==================================================

        settlement = new Settlement();

        // ==================================================
        // 4. Deploy LiquidityBuffer
        // ==================================================

        liquidityBuffer = new LiquidityBuffer();

        // ==================================================
        // 5. Deploy Netting
        // ==================================================

        netting = new Netting(address(this), address(usdc), address(bond), address(settlement));

        // ==================================================
        // 6. Two-phase initialization
        // ==================================================

        // Settlement -> Netting
        settlement.setNetting(address(netting));

        // Settlement -> LiquidityBuffer
        settlement.setLiquidityBuffer(address(liquidityBuffer));

        // LiquidityBuffer -> Settlement
        liquidityBuffer.setSettlement(address(settlement));

        // ==================================================
        // 7. Mint user assets
        // ==================================================

        usdc.mint(alice, 1_000 * USDC);
        bond.mint(bob, 10);

        // ==================================================
        // 8. Mint liquidity for LiquidityBuffer
        // ==================================================

        usdc.mint(liquidityProvider, 1_000 * USDC);

        // ==================================================
        // 9. User approvals
        // ==================================================

        vm.prank(alice);

        usdc.approve(address(settlement), type(uint256).max);

        vm.prank(bob);

        bond.approve(address(settlement), type(uint256).max);

        // ==================================================
        // 10. Liquidity provider approval
        // ==================================================

        vm.prank(liquidityProvider);

        usdc.approve(address(liquidityBuffer), type(uint256).max);

        // ==================================================
        // 11. Deposit USDC into LiquidityBuffer
        // ==================================================

        vm.prank(liquidityProvider);

        liquidityBuffer.deposit(address(usdc), 1_000 * USDC);
    }

    function testFullFlow() public {
        // ==================================================
        // 1. Initial balances
        // ==================================================

        assertEq(usdc.balanceOf(alice), 1_000 * USDC);

        assertEq(usdc.balanceOf(bob), 0);

        assertEq(bond.balanceOf(alice), 0);

        assertEq(bond.balanceOf(bob), 10);

        assertEq(liquidityBuffer.liquidity(address(usdc)), 1_000 * USDC);

        // ==================================================
        // 2. Submit trade
        //
        // Alice buys 5 BOND from Bob
        //
        // Alice pays 500 USDC
        // Bob pays 5 BOND
        // ==================================================

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        assertEq(netting.tradeCount(netting.currentWindowId()), 1);

        // ==================================================
        // 3. Before settlement
        //
        // submitTrade() should NOT move assets.
        // ==================================================

        assertEq(usdc.balanceOf(alice), 1_000 * USDC);

        assertEq(bond.balanceOf(bob), 10);

        // ==================================================
        // 4. Move blockchain forward
        // ==================================================

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);

        assertEq(netting.blocksRemaining(), 0);

        vm.roll(netting.windowStartBlock() + 13);

        // ==================================================
        // 5. Execute Window
        // ==================================================

        netting.executeWindow();

        // ==================================================
        // 6. Final balances
        // ==================================================

        // Alice:
        //
        // 1000 USDC -> 500 USDC
        // 0 BOND    -> 5 BOND

        assertEq(usdc.balanceOf(alice), 500 * USDC);

        assertEq(bond.balanceOf(alice), 5);

        // Bob:
        //
        // 0 USDC -> 500 USDC
        // 10 BOND -> 5 BOND

        assertEq(usdc.balanceOf(bob), 500 * USDC);

        assertEq(bond.balanceOf(bob), 5);

        // ==================================================
        // 7. LiquidityBuffer
        //
        // This trade does NOT need liquidity because
        // Alice has enough USDC.
        //
        // Therefore:
        //
        // Initial liquidity = 1000 USDC
        // Buffer liquidity    = 1000 USDC
        // Debt              = 0
        // ==================================================

        assertEq(liquidityBuffer.liquidity(address(usdc)), 1_000 * USDC);

        assertEq(liquidityBuffer.debt(alice, address(usdc)), 0);

        // ==================================================
        // 8. Window should advance
        // ==================================================

        assertEq(netting.currentWindowId(), 1);

        assertEq(netting.tradeCount(netting.currentWindowId()), 0);
    }

    function testLiquidityShortfallFlow() public {
        // ==================================================
        // 1. Alice only has 200 USDC
        // ==================================================

        uint256 initialAliceBalance = usdc.balanceOf(alice);

        assertEq(initialAliceBalance, 1_000 * USDC);

        // Reduce Alice's balance to 200 USDC.
        vm.prank(alice);
        usdc.transfer(address(0x999), 800 * USDC);

        assertEq(usdc.balanceOf(alice), 200 * USDC);

        // ==================================================
        // 2. LiquidityBuffer has 1000 USDC
        // ==================================================

        assertEq(liquidityBuffer.liquidity(address(usdc)), 1_000 * USDC);

        // ==================================================
        // 3. Alice buys 5 BOND for 500 USDC
        // ==================================================

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        // ==================================================
        // 4. Close window
        // ==================================================

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);

        vm.roll(netting.windowStartBlock() + 13);

        // ==================================================
        // 5. Execute settlement
        // ==================================================

        netting.executeWindow();

        // ==================================================
        // 6. Final balances
        //
        // Alice:
        // 200 USDC -> 0 USDC
        // 0 BOND   -> 5 BOND
        //
        // LiquidityBuffer:
        // provides 300 USDC
        //
        // Bob:
        // 0 USDC -> 500 USDC
        // 10 BOND -> 5 BOND
        // ==================================================

        assertEq(usdc.balanceOf(alice), 0);

        assertEq(bond.balanceOf(alice), 5);

        assertEq(usdc.balanceOf(bob), 500 * USDC);

        assertEq(bond.balanceOf(bob), 5);

        // ==================================================
        // 7. LiquidityBuffer state
        //
        // Initial liquidity = 1000
        // Buffer provides     = 300
        // Remaining         = 700
        // ==================================================

        assertEq(liquidityBuffer.liquidity(address(usdc)), 700 * USDC);

        // Alice now owes the Buffer 300 USDC.
        assertEq(liquidityBuffer.debt(alice, address(usdc)), 300 * USDC);

        // ==================================================
        // 8. Alice repays the debt
        // ==================================================

        usdc.mint(alice, 300 * USDC);

        vm.prank(alice);

        usdc.approve(address(liquidityBuffer), 300 * USDC);

        vm.prank(alice);

        liquidityBuffer.repay(address(usdc), 300 * USDC);

        // ==================================================
        // 9. Debt should be zero
        // ==================================================

        assertEq(liquidityBuffer.debt(alice, address(usdc)), 0);

        // ==================================================
        // 10. Liquidity should be restored
        // ==================================================

        assertEq(liquidityBuffer.liquidity(address(usdc)), 1_000 * USDC);
    }
}
