// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {MockBond} from "../../src/tokens/MockBond.sol";

import {Settlement} from "../../src/core/Settlement.sol";
import {Netting} from "../../src/core/Netting.sol";
import {LiquidityPool} from "../../src/core/LiquidityPool.sol";
import {Types} from "../../src/libraries/Types.sol";

contract NettingTest is Test {
    MockUSDC usdc;
    MockBond bond;

    Settlement settlement;
    Netting netting;
    LiquidityPool liquidityPool;

    address alice;
    address bob;
    address charlie;

    uint256 constant USDC = 1_000_000;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy Token
        usdc = new MockUSDC(address(this));
        bond = new MockBond(address(this));

        // Deploy Settlement
        settlement = new Settlement();

        // Deploy LiquidityPool
        liquidityPool = new LiquidityPool();

        // Deploy Netting
        netting = new Netting(
            address(this),
            address(usdc),
            address(bond),
            address(settlement)
        );

        // Two-phase initialization
        settlement.setNetting(address(netting));

        // Settlement -> LiquidityPool
        settlement.setLiquidityPool(address(liquidityPool));

        // LiquidityPool -> Settlement
        liquidityPool.setSettlement(address(settlement));

        // Initial balances
        usdc.mint(alice, 1_000 * USDC);
        bond.mint(bob, 10);

        // Settlement needs allowance
        vm.prank(alice);
        usdc.approve(address(settlement), type(uint256).max);

        vm.prank(bob);
        bond.approve(address(settlement), type(uint256).max);
    }

    // ============================================================
    // 1. Initial state
    // ============================================================

    function testInitialState() public {
        assertEq(netting.currentWindowId(), 0);

        assertEq(netting.windowStartBlock(), block.number);

        assertEq(netting.tradeCount(0), 0);
    }

    // ============================================================
    // 2. Submit trade
    // ============================================================

    function testSubmitTrade() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        assertEq(netting.tradeCount(0), 1);

        Types.Trade memory trade = netting.getTrade(0, 0);

        assertEq(trade.buyer, alice);
        assertEq(trade.seller, bob);
        assertEq(trade.cashAmount, 500 * USDC);
        assertEq(trade.bondAmount, 5);
    }

    // ============================================================
    // 3. Submit trade does not move assets
    // ============================================================

    function testSubmitTradeDoesNotMoveAssets() public {
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);

        uint256 bobBondBefore = bond.balanceOf(bob);

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        assertEq(usdc.balanceOf(alice), aliceUSDCBefore);

        assertEq(bond.balanceOf(bob), bobBondBefore);
    }

    // ============================================================
    // 4. blocksRemaining
    // ============================================================

    function testBlocksRemaining() public {
        uint256 remaining = netting.blocksRemaining();

        assertGt(remaining, 0);

        vm.roll(block.number + remaining);

        assertEq(netting.blocksRemaining(), 0);
    }

    // ============================================================
    // 5. Cannot execute before window closes
    // ============================================================

    function testCannotExecuteBeforeWindowCloses() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        vm.expectRevert();

        netting.executeWindow();
    }

    // ============================================================
    // 6. Non-owner cannot execute window
    // ============================================================

    function testNonOwnerCannotExecuteWindow() public {
        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);

        vm.prank(alice);

        vm.expectRevert();

        netting.executeWindow();
    }

    // ============================================================
    // 7. Preview net positions
    // ============================================================

    function testPreviewNetPositions() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        Types.NetPosition[] memory positions = netting.previewNetPositions();

        assertEq(positions.length, 4);

        // Alice USDC
        assertEq(positions[0].participant, alice);

        assertEq(positions[0].asset, address(usdc));

        assertEq(positions[0].amount, -int256(500 * USDC));

        // Bob USDC
        assertEq(positions[1].participant, bob);

        assertEq(positions[1].asset, address(usdc));

        assertEq(positions[1].amount, int256(500 * USDC));

        // Alice BOND
        assertEq(positions[2].participant, alice);

        assertEq(positions[2].asset, address(bond));

        assertEq(positions[2].amount, int256(5));

        // Bob BOND
        assertEq(positions[3].participant, bob);

        assertEq(positions[3].asset, address(bond));

        assertEq(positions[3].amount, -int256(5));
    }

    // ============================================================
    // 8. Execute successful settlement
    // ============================================================

    function testExecuteWindow() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);

        netting.executeWindow();

        // Alice
        assertEq(usdc.balanceOf(alice), 500 * USDC);

        assertEq(bond.balanceOf(alice), 5);

        // Bob
        assertEq(usdc.balanceOf(bob), 500 * USDC);

        assertEq(bond.balanceOf(bob), 5);
    }

    // ============================================================
    // 9. Window advances after successful settlement
    // ============================================================

    function testWindowAdvancesAfterSettlement() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);

        netting.executeWindow();

        assertEq(netting.currentWindowId(), 1);

        assertEq(netting.tradeCount(0), 0);

        assertEq(netting.tradeCount(1), 0);
    }

    // ============================================================
    // 10. Zero address rejected
    // ============================================================

    function testZeroAddressRejected() public {
        vm.expectRevert();

        netting.submitTrade(address(0), bob, 500 * USDC, 5);
    }

    // ============================================================
    // 11. Same participant rejected
    // ============================================================

    function testSameParticipantRejected() public {
        vm.expectRevert();

        netting.submitTrade(alice, alice, 500 * USDC, 5);
    }

    // ============================================================
    // 12. Zero cash rejected
    // ============================================================

    function testZeroCashRejected() public {
        vm.expectRevert();

        netting.submitTrade(alice, bob, 0, 5);
    }

    // ============================================================
    // 13. Zero bond rejected
    // ============================================================

    function testZeroBondRejected() public {
        vm.expectRevert();

        netting.submitTrade(alice, bob, 500 * USDC, 0);
    }

    // ============================================================
    // 14. Empty window can still advance
    // ============================================================

    function testEmptyWindowCanAdvance() public {
        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);

        netting.executeWindow();

        assertEq(netting.currentWindowId(), 1);
    }

    function testGetDashboardMetrics() public {
        (
            uint256 totalSettlementAmount,
            uint256 netSettlementAmount,
            uint256 liquiditySaved,
            uint256 obligationReduction
        ) = netting.getPublicAnalyticsMetrics();

        assertEq(totalSettlementAmount, 0);
        assertEq(netSettlementAmount, 0);
        assertEq(liquiditySaved, 0);
        assertEq(obligationReduction, 0);
    }

    function testDashboardMetrics() public {
        // Alice -> Bob: 500 USDC
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        // Bob -> Charlie: 400 USDC
        netting.submitTrade(bob, charlie, 400 * USDC, 4);

        // Charlie -> Alice: 300 USDC
        netting.submitTrade(charlie, alice, 300 * USDC, 3);

        (
            uint256 totalSettlementAmount,
            uint256 netSettlementAmount,
            uint256 liquiditySaved,
            uint256 obligationReduction
        ) = netting.getPublicAnalyticsMetrics();

        // Total before netting:
        // 500 + 400 + 300 = 1200 USDC
        assertEq(totalSettlementAmount, 1200 * USDC);

        // Net positions:
        //
        // Alice:
        // -500 + 300 = -200
        //
        // Bob:
        // +500 - 400 = +100
        //
        // Charlie:
        // +400 - 300 = +100
        //
        // Actual cash settlement = 200 USDC
        assertEq(netSettlementAmount, 200 * USDC);

        // 1200 - 200 = 1000 USDC
        assertEq(liquiditySaved, 1000 * USDC);

        // 1000 / 1200 * 10000 = 8333
        // 8333 = 83.33%
        assertEq(obligationReduction, 8333);
    }
}
