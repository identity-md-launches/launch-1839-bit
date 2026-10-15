// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BIT} from "../src/BIT.sol";
import {FactoryHarness} from "./helpers/FactoryHarness.sol";

contract BITTest is Test {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    BIT internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new BIT();
    }

    function test_MetadataAndInitialSupply() public view {
        assertEq(token.name(), "BIT");
        assertEq(token.symbol(), "BIT");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ConstructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        BIT created = new BIT();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].emitter, address(created));
        assertEq(entries[0].topics.length, 3);
        assertEq(entries[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(entries[0].topics[1], bytes32(0));
        assertEq(entries[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(entries[0].data, (uint256)), SUPPLY);
    }

    function test_Create2MintsOnlyToImmediateDeployer() public {
        FactoryHarness factory = new FactoryHarness();
        bytes32 salt = keccak256("BIT local deployment");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), salt, keccak256(type(BIT).creationCode)
                        )
                    )
                )
            )
        );

        vm.prank(alice, alice);
        BIT created = factory.deploy(salt);
        assertEq(address(created), predicted);
        assertEq(created.totalSupply(), SUPPLY);
        assertEq(created.balanceOf(address(factory)), SUPPLY);
        assertEq(created.balanceOf(alice), 0);
        assertEq(created.balanceOf(address(this)), 0);
    }

    function test_LaunchDistributionAndTradingTransfersArriveWhole() public {
        FactoryHarness factory = new FactoryHarness();
        BIT created = factory.deploy(keccak256("BIT transfer flows"));
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool manager");
        address remainder = makeAddr("remainder recipient");
        uint256 swarm = SUPPLY * 10 / 100;
        uint256 liquidity = SUPPLY * 88 / 100;
        uint256 rest = SUPPLY - swarm - liquidity;

        assertTrue(factory.move(created, distributor, swarm));
        assertTrue(factory.move(created, pool, liquidity));
        assertTrue(factory.move(created, remainder, rest));
        assertEq(created.balanceOf(address(factory)), 0);
        assertEq(created.balanceOf(distributor), swarm);
        assertEq(created.balanceOf(pool), liquidity);
        assertEq(created.balanceOf(remainder), rest);

        vm.prank(distributor);
        assertTrue(created.transfer(alice, swarm));
        assertEq(created.balanceOf(alice), swarm);
        assertEq(created.balanceOf(distributor), 0);

        // Model the token legs of a purchase and sale; this is not a DEX pricing test.
        vm.prank(pool);
        assertTrue(created.transfer(bob, 100 ether));
        assertEq(created.balanceOf(bob), 100 ether);
        vm.prank(bob);
        assertTrue(created.transfer(pool, 100 ether));
        assertEq(created.balanceOf(bob), 0);
        assertEq(created.balanceOf(pool), liquidity);
        assertEq(created.totalSupply(), SUPPLY);
    }

    function test_TransferReturnsTrueAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 25 ether);
        assertTrue(token.transfer(alice, 25 ether));
        assertEq(token.balanceOf(alice), 25 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 25 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEntireSupply() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenTransferExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenSelfTransferExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_RevertWhenTransferToZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenZeroTransferToZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_RevertWhenTransferFromZeroSender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
    }

    function test_ApproveReturnsTrueAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 50 ether);
        assertTrue(token.approve(spender, 50 ether));
        assertEq(token.allowance(address(this), spender), 50 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApprovalReplacesPreviousValue() public {
        assertTrue(token.approve(spender, 50 ether));
        assertTrue(token.approve(spender, 7 ether));
        assertEq(token.allowance(address(this), spender), 7 ether);
    }

    function test_RevokedApprovalCannotBeSpent() public {
        assertTrue(token.approve(spender, 50 ether));
        assertTrue(token.approve(spender, 0));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ApprovalDoesNotRequireBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_RevertWhenApproveFromZeroSender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);
    }

    function test_TransferFromConsumesFiniteAllowanceAndEmitsTransfer() public {
        assertTrue(token.approve(spender, 50 ether));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 20 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 20 ether));
        assertEq(token.allowance(address(this), spender), 30 ether);
        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 20 ether);
        assertEq(token.balanceOf(spender), 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 30 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), 30 ether);
    }

    function test_TransferFromPreservesInfiniteAllowance() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_TransferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        assertTrue(token.approve(spender, 3 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 3 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ZeroTransferFromNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertWhenTransferFromExceedsAllowance() public {
        assertTrue(token.approve(spender, 2 ether));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2 ether, 3 ether
            )
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 3 ether);
        assertEq(token.allowance(address(this), spender), 2 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenUnapprovedSpenderTriesAnotherSpendersAllowance() public {
        assertTrue(token.approve(spender, 2 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 2 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_RevertWhenDeployerTriesToSeizeHolderBalance() public {
        assertTrue(token.transfer(alice, 10 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1)
        );
        token.transferFrom(alice, address(this), 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_FailedTransferFromRestoresAllowanceWhenBalanceTooLow() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 10 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10 ether)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FailedTransferFromRestoresAllowanceWhenRecipientIsZero() public {
        assertTrue(token.approve(spender, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoMintBurnOrAdministrativeEntryPoints() public {
        assertTrue(token.transfer(alice, 10 ether));
        bytes[] memory calls = new bytes[](16);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("freeze(address)", alice);
        calls[8] = abi.encodeWithSignature("seize(address)", alice);
        calls[9] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[10] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[11] = abi.encodeWithSignature("initialize(address)", bob);
        calls[12] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[13] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[14] = abi.encodeWithSignature("setOwner(address)", bob);
        calls[15] = abi.encodeWithSignature("issue(uint256)", 1 ether);

        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(token).call(calls[i]);
            assertFalse(deployerOk, "deployer reached an unexpected entry point");
            vm.prank(bob);
            (bool strangerOk,) = address(token).call(calls[i]);
            assertFalse(strangerOk, "stranger reached an unexpected entry point");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 10 ether);
            assertEq(token.balanceOf(bob), 0);
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_RuntimeFitsDeploymentLimitAndContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
            }
        }
    }

    function testFuzz_TransfersConserveSupply(address recipient, uint256 rawAmount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedTransfersSpendExactFiniteAllowance(uint256 rawAmount, uint256 rawAllowance)
        public
    {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 allowed = bound(rawAllowance, amount, type(uint256).max - 1);
        assertTrue(token.approve(spender, allowed));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(address(this), spender), allowed - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertWhenTransferExceedsEntireSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount
            )
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertWhenSpenderExceedsAllowance(uint256 rawAllowance, uint256 rawAmount) public {
        uint256 allowed = bound(rawAllowance, 0, SUPPLY - 1);
        uint256 amount = bound(rawAmount, allowed + 1, SUPPLY);
        assertTrue(token.approve(spender, allowed));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), allowed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
