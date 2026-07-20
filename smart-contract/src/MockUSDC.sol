// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "MUSDC") {
        _mint(msg.sender, 1000 * 100 * 1e6);
    }

    // Add mint function for testing.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Add burn function for testing
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
