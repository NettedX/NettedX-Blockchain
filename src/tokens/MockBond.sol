// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockBond is ERC20, Ownable {
    constructor(address initialOwner) ERC20("Mock Bond", "mBOND") Ownable(initialOwner) {}

    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address");

        _mint(to, amount);
    }
}
