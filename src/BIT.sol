// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BIT
/// @notice Fixed-supply ERC-20: 100,000,000 BIT with 18 decimals.
/// @dev The immediate deployer receives the entire supply. No mint, burn, or admin entry points exist.
contract BIT is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10 ** 18;

    constructor() ERC20("BIT", "BIT") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
