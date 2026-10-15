// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BIT} from "../../src/BIT.sol";

/// @dev Local test helper only. Models CREATE2 deployment and transfers by the launch factory.
contract FactoryHarness {
    function deploy(bytes32 salt) external returns (BIT) {
        return new BIT{salt: salt}();
    }

    function move(BIT token, address recipient, uint256 amount) external returns (bool) {
        return token.transfer(recipient, amount);
    }
}
