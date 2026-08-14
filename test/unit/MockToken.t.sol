// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/src//tokens/MockUSDC.sol";
import {MockBond} from "../../src/src/tokens/MockBond.sol";

contract MockTokenTest is Test {
    MockUSDC usdc;
    MockBond bond;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        usdc = new MockUSDC(address(this));
        bond = new MockBond(address(this));
    }

    function testUSDCDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function testBondDecimals() public view {
        assertEq(bond.decimals(), 0);
    }

    function testMint() public {
        usdc.mint(alice, 1_000_000);

        assertEq(usdc.balanceOf(alice), 1_000_000);
    }

    function testTransfer() public {
        usdc.mint(alice, 1_000_000);

        vm.prank(alice);
        usdc.transfer(bob, 400_000);

        assertEq(usdc.balanceOf(alice), 600_000);

        assertEq(usdc.balanceOf(bob), 400_000);
    }

    function testApproveTransferFrom() public {
        usdc.mint(alice, 1_000_000);

        vm.prank(alice);
        usdc.approve(bob, 500_000);

        vm.prank(bob);
        usdc.transferFrom(alice, bob, 500_000);

        assertEq(usdc.balanceOf(alice), 500_000);

        assertEq(usdc.balanceOf(bob), 500_000);
    }
}
