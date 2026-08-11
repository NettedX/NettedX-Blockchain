// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Netting } from "../src/Netting.sol";

contract Deploy is Script {
    function run() external returns (Netting deployed) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address matcher = vm.envAddress("MATCHER_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address cashToken = vm.envAddress("CASH_TOKEN_ADDRESS");
        address bondToken = vm.envAddress("BOND_TOKEN_ADDRESS");
        address settlement = vm.envAddress("SETTLEMENT_ADDRESS");

        vm.startBroadcast(privateKey);
        deployed = new Netting(admin, matcher, operator, cashToken, bondToken, settlement);
        vm.stopBroadcast();
    }
}
