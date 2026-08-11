// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Netting } from "../src/Netting.sol";
import { NetPosition } from "../src/Types.sol";
import { MockSettlement } from "./mocks/MockSettlement.sol";
import { MockToken } from "./mocks/MockToken.sol";

interface Vm {
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
}
contract NettingTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant USDC = 1e6;
    int256 private constant IUSDC = 1e6;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant STRANGER = address(0xBAD);

    MockToken private cash;
    MockToken private bond;
    MockSettlement private settlement;
    Netting private netting;

    function setUp() public {
        cash = new MockToken("Mock USDC", "mUSDC", 6);
        bond = new MockToken("Mock Bond", "mBOND", 0);
        settlement = new MockSettlement();
        netting = new Netting(
            address(this),
            address(this),
            address(this),
            address(cash),
            address(bond),
            address(settlement)
        );
        settlement.setNetting(address(netting));
    }

    function test_MultilateralNettingAndAtomicSettlement() public {
        cash.mint(ALICE, 2_000 * USDC);
        bond.mint(BOB, 10);
        bond.mint(CAROL, 3);
        _approve(ALICE, cash, 2_000 * USDC);
        _approve(BOB, bond, 10);
        _approve(CAROL, bond, 3);

        netting.submitTrade(ALICE, BOB, 1_000 * USDC, 10);
        netting.submitTrade(BOB, ALICE, 500 * USDC, 5);
        netting.submitTrade(ALICE, CAROL, 300 * USDC, 3);

        assertEq(netting.getNetPosition(1, ALICE, address(cash)), -800 * IUSDC);
        assertEq(netting.getNetPosition(1, ALICE, address(bond)), 8);
        assertEq(netting.getNetPosition(1, BOB, address(cash)), 500 * IUSDC);
        assertEq(netting.getNetPosition(1, CAROL, address(cash)), 300 * IUSDC);

        _closeAndMature();
        assertTrue(netting.settleWindow());

        assertEq(cash.balanceOf(ALICE), 1_200 * USDC);
        assertEq(cash.balanceOf(BOB), 500 * USDC);
        assertEq(cash.balanceOf(CAROL), 300 * USDC);
        assertEq(bond.balanceOf(ALICE), 8);
        assertEq(bond.balanceOf(BOB), 5);
        assertEq(bond.balanceOf(CAROL), 0);
        assertEq(netting.currentWindowId(), 2);
        assertEq(uint256(netting.windowStatus(1)), uint256(Netting.WindowStatus.Settled));
    }

    function test_RepeatedExclusionRollsEveryAffectedTradeForward() public {
        cash.mint(ALICE, 80 * USDC);
        bond.mint(BOB, 1);
        _approve(ALICE, cash, 80 * USDC);
        _approve(BOB, bond, 1);

        // Initially Alice owes 80 net. Carol's exclusion removes Alice's incoming 20,
        // making Alice owe 100 and causing a second exclusion round.
        netting.submitTrade(ALICE, BOB, 100 * USDC, 1);
        netting.submitTrade(CAROL, ALICE, 20 * USDC, 1);

        _closeAndMature();
        assertTrue(netting.settleWindow());

        assertEq(settlement.lastPositionCount(), 0);
        assertEq(netting.currentWindowId(), 2);
        assertEq(netting.getNetPosition(2, ALICE, address(cash)), -80 * IUSDC);
        assertEq(netting.getNetPosition(2, BOB, address(cash)), 100 * IUSDC);
        assertEq(netting.getNetPosition(2, CAROL, address(cash)), -20 * IUSDC);
        assertEq(netting.getParticipants(2).length, 3);
    }

    function test_SettlementFailureLeavesFrozenWindowRetryable() public {
        cash.mint(ALICE, 100 * USDC);
        bond.mint(BOB, 1);
        _approve(ALICE, cash, 100 * USDC);
        _approve(BOB, bond, 1);
        netting.submitTrade(ALICE, BOB, 100 * USDC, 1);

        _closeAndMature();
        settlement.setShouldFail(true);
        assertFalse(netting.settleWindow());
        assertEq(uint256(netting.windowStatus(1)), uint256(Netting.WindowStatus.Frozen));
        assertEq(netting.currentWindowId(), 1);

        settlement.setShouldFail(false);
        assertTrue(netting.settleWindow());
        assertEq(netting.currentWindowId(), 2);
    }

    function test_DeadlineIsImmutableAndLateTradesAreRejected() public {
        uint256 deadline = netting.closeEligibleBlock();
        vm.roll(deadline);
        vm.expectRevert(abi.encodeWithSelector(Netting.WindowExpired.selector, deadline, deadline));
        netting.submitTrade(ALICE, BOB, 1, 1);
    }

    function test_OnlyMatcherCanSubmit() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        netting.submitTrade(ALICE, BOB, 1, 1);
    }

    function test_CloseAndSettlementRespectBlockBoundaries() public {
        vm.expectRevert();
        netting.closeWindow();

        vm.roll(netting.closeEligibleBlock());
        netting.closeWindow();
        vm.expectRevert();
        netting.settleWindow();

        vm.roll(netting.settleEligibleBlock(1));
        assertTrue(netting.settleWindow());
    }

    function test_CheckShortfallsRequiresBothBalanceAndAllowance() public {
        cash.mint(ALICE, 100 * USDC);
        bond.mint(BOB, 1);
        netting.submitTrade(ALICE, BOB, 100 * USDC, 1);

        NetPosition[] memory beforeApprovals = netting.checkShortfalls(1);
        assertEq(beforeApprovals.length, 2);

        _approve(ALICE, cash, 100 * USDC);
        _approve(BOB, bond, 1);
        NetPosition[] memory afterApprovals = netting.checkShortfalls(1);
        assertEq(afterApprovals.length, 0);
    }

    function test_BilateralEdgesAggregateInsteadOfGrowingPerTrade() public {
        netting.submitTrade(ALICE, BOB, 100 * USDC, 10);
        netting.submitTrade(ALICE, BOB, 50 * USDC, 5);
        netting.submitTrade(BOB, ALICE, 20 * USDC, 2);

        assertEq(netting.getEdges(1).length, 2);
        assertEq(netting.getNetPosition(1, ALICE, address(cash)), -130 * IUSDC);
        assertEq(netting.getNetPosition(1, ALICE, address(bond)), 13);
    }

    function test_PauseStopsTradeSubmission() public {
        netting.pause();
        vm.expectRevert();
        netting.submitTrade(ALICE, BOB, 1, 1);
        netting.unpause();
        netting.submitTrade(ALICE, BOB, 1, 1);
    }

    function test_NextWindowLengthDoesNotChangeCurrentDeadline() public {
        uint256 currentDeadline = netting.closeEligibleBlock();
        netting.setNextWindowLength(20);
        assertEq(netting.closeEligibleBlock(), currentDeadline);

        _closeAndMature();
        assertTrue(netting.settleWindow());
        (,,, uint64 length,,,,) = netting.windows(2);
        assertEq(uint256(length), 20);
    }

    function testFuzz_PreviewAlwaysConservesBothAssets(uint96 cashSeed, uint64 bondSeed) public {
        uint256 cashAmount = uint256(cashSeed) + 1;
        uint256 bondAmount = uint256(bondSeed) + 1;
        netting.submitTrade(ALICE, BOB, cashAmount, bondAmount);

        int256 cashSum = netting.getNetPosition(1, ALICE, address(cash))
            + netting.getNetPosition(1, BOB, address(cash));
        int256 bondSum = netting.getNetPosition(1, ALICE, address(bond))
            + netting.getNetPosition(1, BOB, address(bond));
        assertEq(cashSum, 0);
        assertEq(bondSum, 0);
    }

    function _closeAndMature() private {
        vm.roll(netting.closeEligibleBlock());
        netting.closeWindow();
        vm.roll(netting.settleEligibleBlock(netting.currentWindowId()));
    }

    function _approve(address owner, MockToken token, uint256 amount) private {
        vm.prank(owner);
        token.approve(address(settlement), amount);
    }

    function assertTrue(bool value) private pure {
        require(value, "assert true failed");
    }

    function assertFalse(bool value) private pure {
        require(!value, "assert false failed");
    }

    function assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "uint equality failed");
    }

    function assertEq(int256 actual, int256 expected) private pure {
        require(actual == expected, "int equality failed");
    }
}
