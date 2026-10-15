// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Local test helper only. Stands in for the launch factory the way the network's floor does:
/// it deploys the token (and any project contracts) through CREATE2 in one call, holds the supply,
/// answers `distributorOf`, and forwards balances. Only the test that created it may drive it.
contract LaunchProbe {
    address private immutable controller = msg.sender;
    mapping(uint64 => address) public distributorOf;

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    /// @notice Deploys every creation code at its salt in one transaction, checking after each
    /// constructor that the whole expected supply exists and is still held here.
    function deployAll(bytes[] memory codes, bytes32[] memory salts, uint256 expectedSupply)
        external
        onlyController
        returns (address[] memory deployed)
    {
        require(codes.length > 0 && codes.length == salts.length && codes.length <= 9, "invalid project list");
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
            (bool ok, bytes memory supplyData) =
                deployed[0].staticcall(abi.encodeWithSignature("totalSupply()"));
            require(ok && abi.decode(supplyData, (uint256)) == expectedSupply, "manifest supply mismatch");
            (ok, supplyData) =
                deployed[0].staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
            require(
                ok && abi.decode(supplyData, (uint256)) == expectedSupply,
                "a constructor moved the launch supply"
            );
        }
    }

    /// @notice Deploys one creation code with CREATE and the given ETH value. Returns the zero
    /// address when the constructor rejects the deployment rather than reverting the whole call.
    function tryDeployWithValue(bytes memory code, uint256 value)
        external
        payable
        onlyController
        returns (address created)
    {
        assembly ("memory-safe") {
            created := create(value, add(code, 32), mload(code))
        }
    }

    function setDistributor(uint64 launchNumber, address distributor) external onlyController {
        distributorOf[launchNumber] = distributor;
    }

    function move(address token, address to, uint256 amount) external onlyController returns (bool) {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok) {
            // Bubble the token's own revert data up to the test.
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
        return abi.decode(data, (bool));
    }

    /// @notice Forwards an arbitrary call so the test can try privileged selectors from the factory.
    function callAs(address target, bytes memory data)
        external
        onlyController
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.call(data);
    }

    receive() external payable {}
}
