// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BIT} from "../src/BIT.sol";
import {LaunchProbe} from "./helpers/LaunchProbe.sol";

/// @notice Local mirror of the floor a custom token passes before its launch is admitted, minus the
/// Uniswap v4 seed and swap, which need the network's own infrastructure. The token is deployed the
/// way `launchCustom` deploys it: through CREATE2 from the factory's address, salted with the launch
/// number, in one call, with the probe etched at the factory address rather than created there.
contract BITLaunchFloorTest is Test {
    uint256 internal constant SUPPLY = 100_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_800;
    uint64 internal constant LAUNCH_NUMBER = 42;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant HOLDER = address(0x401D);
    address internal constant OTHER = address(0x07E5);
    address internal constant ATTACKER = address(0xBEEF);

    LaunchProbe internal probe;
    BIT internal token;
    address internal factory;
    address internal remainderTo;

    function setUp() public {
        factory = makeAddr("launch factory");
        remainderTo = makeAddr("requester remainder recipient");

        // The probe's controller is an immutable, so it survives being etched elsewhere.
        LaunchProbe implementation = new LaunchProbe();
        vm.etch(factory, address(implementation).code);
        probe = LaunchProbe(payable(factory));

        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(BIT).creationCode;
        salts[0] = bytes32(uint256(LAUNCH_NUMBER));
        address[] memory deployed = probe.deployAll(codes, salts, SUPPLY);
        token = BIT(deployed[0]);
    }

    function _predicted(bytes32 salt) internal view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), factory, salt, keccak256(type(BIT).creationCode))
                    )
                )
            )
        );
    }

    function test_DeploysAtThePredictedAddressForTheLaunchSalt() public view {
        assertEq(address(token), _predicted(bytes32(uint256(LAUNCH_NUMBER))));
        assertGt(address(token).code.length, 0);
        assertLe(address(token).code.length, 24_576);
    }

    function test_MintsTheManifestSupplyToTheFactory() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply is not what the manifest says");
        assertEq(token.balanceOf(factory), SUPPLY, "the factory does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the transaction signer received supply");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_MetadataMatchesTheManifest() public view {
        assertEq(token.name(), "BIT");
        assertEq(token.symbol(), "BIT");
        assertEq(uint256(token.decimals()), 18, "decimals disagree with the manifest");
        assertEq(SUPPLY, 100_000_000 * 10 ** uint256(token.decimals()));
    }

    function test_RedeployingAtTheSameSaltFails() public {
        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(BIT).creationCode;
        salts[0] = bytes32(uint256(LAUNCH_NUMBER));
        vm.expectRevert(bytes("constructor failed"));
        probe.deployAll(codes, salts, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY);
    }

    function test_DeployAllRejectsAManifestSupplyThatDisagrees() public {
        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(BIT).creationCode;
        salts[0] = bytes32(uint256(LAUNCH_NUMBER) + 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        probe.deployAll(codes, salts, SUPPLY - 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        probe.deployAll(codes, salts, SUPPLY + 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        probe.deployAll(codes, salts, 0);
    }

    function test_ConstructorRejectsEther() public {
        vm.deal(address(this), 1 ether);
        address created = probe.tryDeployWithValue{value: 1 wei}(type(BIT).creationCode, 1 wei);
        assertEq(created, address(0), "a non-payable constructor accepted value");
        assertEq(factory.balance, 1 wei, "the rejected value did not stay with the deployer");

        created = probe.tryDeployWithValue(type(BIT).creationCode, 0);
        assertTrue(created != address(0), "a zero-value deployment failed");
        assertEq(BIT(created).balanceOf(factory), SUPPLY);
    }

    function test_TokenRejectsEtherAndUnknownSelectors() public {
        vm.deal(address(this), 1 ether);
        (bool received,) = address(token).call{value: 1 wei}("");
        assertFalse(received, "the token accepted ether");
        (bool fellBack,) = address(token).call(hex"12345678");
        assertFalse(fellBack, "the token answered an unknown selector");
        (bool fellBackWithValue,) = address(token).call{value: 1 wei}(hex"12345678");
        assertFalse(fellBackWithValue, "the token accepted ether on an unknown selector");
        (bool nonPayableTransfer,) =
            address(token).call{value: 1 wei}(abi.encodeWithSelector(token.transfer.selector, HOLDER, 0));
        assertFalse(nonPayableTransfer, "a non-payable function accepted ether");
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Ten percent leaves the factory whole, and leaves the distributor whole again on a claim.
    function test_TheSwarmShareArrivesWholeAndIsClaimableWhole() public {
        probe.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        assertEq(probe.distributorOf(LAUNCH_NUMBER), DISTRIBUTOR);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(
            probe.move(address(token), DISTRIBUTOR, swarm), "the transfer to the distributor returned false"
        );
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived short");
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm), "the claim transfer returned false");
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    /// @dev The whole launch flow as the factory orders it: swarm share, pool share, remainder. The
    /// token legs of a buy and a sell against the pool arrive whole in both directions.
    function test_TheFullLaunchFlowEmptiesTheFactoryExactly() public {
        address poolManager = makeAddr("pool manager");
        probe.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        assertGt(remainder, 0);

        assertTrue(probe.move(address(token), DISTRIBUTOR, swarm));
        assertTrue(probe.move(address(token), poolManager, pool));
        assertTrue(probe.move(address(token), remainderTo, remainder));
        assertEq(token.balanceOf(factory), 0, "the factory kept something back");
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(remainderTo), remainder);
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(poolManager) + token.balanceOf(remainderTo), SUPPLY
        );

        // The factory holds nothing more: one more wei fails and moves nothing.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, factory, 0, 1));
        probe.move(address(token), remainderTo, 1);

        // Token legs of a trade: the manager pays out exactly, and takes back exactly.
        vm.prank(poolManager);
        assertTrue(token.transfer(OTHER, 1_234_567));
        assertEq(token.balanceOf(OTHER), 1_234_567);
        vm.prank(OTHER);
        assertTrue(token.transfer(poolManager, 1_234_567));
        assertEq(token.balanceOf(OTHER), 0);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The supply may not grow after launch. Neither a stranger nor the factory may reach a mint.
    function test_NoCommonAdminCallIncreasesSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);

            (ok,) = probe.callAs(address(token), data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(factory), SUPPLY, signatures[i]);
        }
    }

    /// @dev Nobody moves or freezes a holder's balance but the holder, the factory included.
    function test_NoPrivilegedHandMovesOrFreezesAHolder() public {
        assertTrue(probe.move(address(token), HOLDER, SUPPLY / 1_000));
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0, "the holder received nothing");
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            (bool ok,) = probe.callAs(address(token), data);
            assertFalse(ok, signatures[i]);
            vm.prank(ATTACKER);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.balanceOf(HOLDER), held, signatures[i]);
        }

        (bool moved, bytes memory reason) = probe.callAs(
            address(token), abi.encodeWithSelector(token.transferFrom.selector, HOLDER, factory, 1)
        );
        assertFalse(moved, "the factory moved a holder's balance without allowance");
        assertEq(
            reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, factory, 0, 1)
        );
        assertEq(token.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");

        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(OTHER), held / 2, "the holder's transfer delivered short");
        assertEq(token.balanceOf(HOLDER), held - held / 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FactoryHasNoRightsOverAnAllowanceItWasNotGiven() public {
        assertTrue(probe.move(address(token), HOLDER, 10 ether));
        vm.prank(HOLDER);
        assertTrue(token.approve(OTHER, 10 ether));
        (bool moved,) = probe.callAs(
            address(token), abi.encodeWithSelector(token.transferFrom.selector, HOLDER, factory, 10 ether)
        );
        assertFalse(moved, "an allowance granted to someone else served the factory");
        assertEq(token.allowance(HOLDER, OTHER), 10 ether);
        assertEq(token.balanceOf(HOLDER), 10 ether);
    }

    function test_RuntimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "the token has no runtime code");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    function test_CreationCodeHasNoUnlinkedLibraryPlaceholders() public pure {
        // solc leaves `__$...$__` placeholders for external libraries; the launch cannot link them.
        bytes memory code = type(BIT).creationCode;
        for (uint256 i; i + 3 < code.length; ++i) {
            bool placeholder = code[i] == "_" && code[i + 1] == "_" && code[i + 2] == "$";
            assertFalse(placeholder, "creation code contains an unlinked library placeholder");
        }
    }
}
