// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {MockBond} from "../../src/tokens/MockBond.sol";

import {Settlement} from "../../src/core/Settlement.sol";
import {Netting} from "../../src/core/Netting.sol";
import {LiquidityBuffer} from "../../src/core/LiquidityBuffer.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract NettingTest is Test {
    MockUSDC usdc;
    MockBond bond;

    Settlement settlement;
    Netting netting;
    LiquidityBuffer liquidityBuffer;

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

        // Deploy LiquidityBuffer
        liquidityBuffer = new LiquidityBuffer();

        // Deploy Netting
        netting = new Netting(address(this), address(usdc), address(bond), address(settlement));

        // Two-phase initialization
        settlement.setNetting(address(netting));

        // Settlement -> LiquidityBuffer
        settlement.setLiquidityBuffer(address(liquidityBuffer));

        // LiquidityBuffer -> Settlement
        liquidityBuffer.setSettlement(address(settlement));

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

    function testAcceptsTradeInTenthBlock() public {
        vm.roll(netting.windowStartBlock() + 9);

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        assertEq(netting.tradeCount(0), 1);
    }

    function testOpensNextWindowInEleventhBlock() public {
        vm.roll(netting.windowStartBlock() + 10);

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        assertEq(netting.tradingWindowId(), 1);
        assertEq(netting.tradeCount(0), 0);
        assertEq(netting.tradeCount(1), 1);
    }

    function testCannotFreezeBeforeEleventhBlock() public {
        vm.expectRevert(Errors.WindowNotClosed.selector);
        netting.freezeWindow();
    }

    function testFreezesCurrentWindowInEleventhBlock() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        vm.roll(netting.windowStartBlock() + 10);
        netting.freezeWindow();
        netting.freezeWindow();

        assertTrue(netting.windowFrozen(0));

        netting.submitTrade(bob, alice, 400 * USDC, 4);

        assertEq(netting.tradeCount(0), 1);
        assertEq(netting.tradeCount(1), 1);
    }

    function testRejectsTradesIfAutomaticOperatorFallsOneWindowBehind() public {
        vm.roll(netting.windowStartBlock() + 20);

        vm.expectRevert(Errors.WindowBacklog.selector);
        netting.submitTrade(alice, bob, 500 * USDC, 5);
    }

    function testAutomationStateTracksFreezeAndSettlement() public {
        (bool freezeNeeded, bool settlementNeeded) = netting.automationState();

        assertFalse(freezeNeeded);
        assertFalse(settlementNeeded);

        vm.roll(netting.windowStartBlock() + 10);

        (freezeNeeded, settlementNeeded) = netting.automationState();

        assertTrue(freezeNeeded);
        assertFalse(settlementNeeded);

        netting.freezeWindow();

        (freezeNeeded, settlementNeeded) = netting.automationState();

        assertFalse(freezeNeeded);
        assertFalse(settlementNeeded);

        vm.roll(netting.windowStartBlock() + 13);

        (freezeNeeded, settlementNeeded) = netting.automationState();

        assertFalse(freezeNeeded);
        assertTrue(settlementNeeded);
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
    // 5. Cannot execute before settlement block
    // ============================================================

    function testCannotExecuteBeforeSettlementBlock() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        vm.expectRevert(Errors.SettlementNotReady.selector);

        netting.executeWindow();
    }

    function testCannotSettleInBlocksElevenToThirteen() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        uint256 startBlock = netting.windowStartBlock();

        for (uint256 offset = 10; offset <= 12; offset++) {
            vm.roll(startBlock + offset);

            vm.expectRevert(Errors.SettlementNotReady.selector);
            netting.executeWindow();
        }
    }

    // ============================================================
    // 6. Non-owner cannot execute window
    // ============================================================

    function testNonOwnerCannotExecuteWindow() public {
        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);
        vm.roll(netting.windowStartBlock() + 13);

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

    function testSettlementWindowForecast() public {
        uint256 startBlock = netting.windowStartBlock();

        Types.SettlementWindowForecast memory forecast = netting.getSettlementWindowForecast();

        assertEq(forecast.windowId, 0);
        assertEq(forecast.settlementBlock, startBlock + 13);
        assertEq(forecast.blocksRemaining, 13);

        vm.roll(startBlock + 10);

        forecast = netting.getSettlementWindowForecast();

        assertEq(forecast.blocksRemaining, 3);

        vm.roll(startBlock + 13);

        forecast = netting.getSettlementWindowForecast();

        assertEq(forecast.blocksRemaining, 0);
    }

    function testBankNetPositionsSeparatePayablesAndReceivables() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        Types.BankNetPosition[] memory positions = netting.getBankNetPositions(alice);

        assertEq(positions.length, 2);

        assertEq(positions[0].asset, address(usdc));
        assertEq(positions[0].payableAmount, 500 * USDC);
        assertEq(positions[0].receivableAmount, 0);

        assertEq(positions[1].asset, address(bond));
        assertEq(positions[1].payableAmount, 0);
        assertEq(positions[1].receivableAmount, 5);
    }

    function testBankSettlementAssetRequirementsOnlyIncludePayables() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        Types.SettlementAssetRequirement[] memory aliceRequirements = netting.getBankSettlementAssetRequirements(alice);
        Types.SettlementAssetRequirement[] memory bobRequirements = netting.getBankSettlementAssetRequirements(bob);

        assertEq(aliceRequirements.length, 1);
        assertEq(aliceRequirements[0].asset, address(usdc));
        assertEq(aliceRequirements[0].requiredAmount, 500 * USDC);

        assertEq(bobRequirements.length, 1);
        assertEq(bobRequirements[0].asset, address(bond));
        assertEq(bobRequirements[0].requiredAmount, 5);
    }

    function testBankLiquidityShortfallsReturnExpectedBorrowAmount() public {
        usdc.mint(charlie, 200 * USDC);
        netting.submitTrade(charlie, bob, 500 * USDC, 5);

        Types.LiquidityShortfall[] memory shortfalls = netting.getBankLiquidityShortfalls(charlie);

        assertEq(shortfalls.length, 1);
        assertEq(shortfalls[0].asset, address(usdc));
        assertEq(shortfalls[0].requiredAmount, 500 * USDC);
        assertEq(shortfalls[0].availableBalance, 200 * USDC);
        assertEq(shortfalls[0].borrowAmount, 300 * USDC);
    }

    function testDashboardInterfacesRejectZeroBankAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        netting.getBankNetPositions(address(0));

        vm.expectRevert(Errors.ZeroAddress.selector);
        netting.getBankSettlementAssetRequirements(address(0));

        vm.expectRevert(Errors.ZeroAddress.selector);
        netting.getBankLiquidityShortfalls(address(0));
    }

    // ============================================================
    // 8. Execute successful settlement
    // ============================================================

    function testExecuteWindow() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        uint256 remaining = netting.blocksRemaining();

        vm.roll(block.number + remaining);
        vm.roll(netting.windowStartBlock() + 13);

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
        vm.roll(netting.windowStartBlock() + 13);

        netting.executeWindow();

        assertEq(netting.currentWindowId(), 1);

        assertEq(netting.tradeCount(0), 0);

        assertEq(netting.tradeCount(1), 0);
    }

    function testNextWindowTradesContinueDuringSettlement() public {
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        vm.roll(netting.windowStartBlock() + 10);
        netting.freezeWindow();
        netting.submitTrade(bob, alice, 400 * USDC, 4);

        vm.roll(netting.windowStartBlock() + 13);
        netting.executeWindow();

        netting.submitTrade(alice, bob, 500 * USDC, 5);

        assertEq(netting.currentWindowId(), 1);
        assertEq(netting.tradingWindowId(), 1);
        assertEq(netting.tradeCount(1), 2);
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
        vm.roll(netting.windowStartBlock() + 13);

        netting.executeWindow();

        assertEq(netting.currentWindowId(), 1);
    }

    function testGetPublicAnalyticsMetricsEmptyWindow() public {
        (uint256 totalSettlementAmount, uint256 totalTradeCount, uint256 liquiditySaved, uint256 obligationReduction) =
            netting.getPublicAnalyticsMetrics();

        assertEq(totalSettlementAmount, 0);

        assertEq(totalTradeCount, 0);
        assertEq(liquiditySaved, 0);
        assertEq(obligationReduction, 0);
    }

    function testGetPublicAnalyticsMetrics() public {
        // Alice -> Bob: 500 USDC
        netting.submitTrade(alice, bob, 500 * USDC, 5);

        // Bob -> Charlie: 400 USDC
        netting.submitTrade(bob, charlie, 400 * USDC, 4);

        // Charlie -> Alice: 300 USDC
        netting.submitTrade(charlie, alice, 300 * USDC, 3);

        (uint256 totalSettlementAmount, uint256 totalTradeCount, uint256 liquiditySaved, uint256 obligationReduction) =
            netting.getPublicAnalyticsMetrics();

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
        // Three original trades were submitted.
        assertEq(totalTradeCount, 3);

        // 1200 - 200 = 1000 USDC
        assertEq(liquiditySaved, 1000 * USDC);

        // 1000 / 1200 * 10000 = 8333
        // 1000 / 1200 * 100 = 83
        // 83 = 83.33% rounded down
        assertEq(obligationReduction, 83);
    }
}
