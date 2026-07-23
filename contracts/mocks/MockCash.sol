// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable stablecoin stand-in for tests and testnet deploys.
contract MockCash is ERC20 {
    constructor() ERC20("Mock EURC", "mEURC") {
        _mint(msg.sender, 1_000_000 ether);
    }
}
