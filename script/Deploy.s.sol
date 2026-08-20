// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {MockUSDC} from "../src/tokens/MockUSDC.sol";
import {MockBond} from "../src/tokens/MockBond.sol";

import {Settlement} from "../src/core/Settlement.sol";
import {Netting} from "../src/core/Netting.sol";
import {LiquidityBuffer} from "../src/core/LiquidityBuffer.sol";

contract Deploy is Script {
    function run()
        external
        returns (MockUSDC usdc, MockBond bond, Settlement settlement, Netting netting, LiquidityBuffer liquidityBuffer)
    {
        // =========================================================
        // Get deployer private key
        // =========================================================

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deployer:", deployer);

        // =========================================================
        // Start deployment
        // =========================================================

        vm.startBroadcast(deployerPrivateKey);

        // =========================================================
        // 1. Deploy MockUSDC
        // =========================================================

        usdc = new MockUSDC(deployer);

        // =========================================================
        // 2. Deploy MockBond
        // =========================================================

        bond = new MockBond(deployer);

        // =========================================================
        // 3. Deploy Settlement
        // =========================================================

        settlement = new Settlement();

        // =========================================================
        // 4. Deploy Netting
        // =========================================================

        netting = new Netting(deployer, address(usdc), address(bond), address(settlement));

        // =========================================================
        // 5. Deploy LiquidityBuffer
        // =========================================================

        liquidityBuffer = new LiquidityBuffer();

        // =========================================================
        // 6. Initialize Settlement -> Netting
        // =========================================================

        settlement.setNetting(address(netting));

        // =========================================================
        // 7. Initialize Settlement -> LiquidityBuffer
        // =========================================================

        settlement.setLiquidityBuffer(address(liquidityBuffer));

        // =========================================================
        // 8. Initialize LiquidityBuffer -> Settlement
        // =========================================================

        liquidityBuffer.setSettlement(address(settlement));

        // =========================================================
        // Stop deployment
        // =========================================================

        vm.stopBroadcast();

        // =========================================================
        // Print deployed addresses
        // =========================================================

        console2.log("USDC:", address(usdc));

        console2.log("BOND:", address(bond));

        console2.log("SETTLEMENT:", address(settlement));

        console2.log("NETTING:", address(netting));

        console2.log("LIQUIDITY_BUFFER:", address(liquidityBuffer));
    }
}
