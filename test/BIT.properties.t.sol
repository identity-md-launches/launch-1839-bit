// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BIT} from "../src/BIT.sol";

/// @notice Stateless properties at the arithmetic edges: round trips, boundaries between finite and
/// unlimited allowances, exact-allowance spends, last-write-wins approvals, and failed calls that
/// must leave every balance and allowance untouched. Inputs are constrained with `bound`, never
/// discarded, so every run checks something.
/// forge-config: default.fuzz.runs = 1024
contract BITPropertiesTest is Test {
    uint256 internal constant SUPPLY = 100_000_000 * 10 ** 18;
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

    function _actor(uint256 seed) internal view returns (address) {
        address[4] memory actors = [address(this), alice, bob, spender];
        return actors[seed % actors.length];
    }

    /// @dev A fresh address with no code: not zero, not a precompile, not one of the fixed actors.
    function _external(address raw) internal returns (address a) {
        a = address(uint160(bound(uint256(uint160(raw)), 0x10000, type(uint160).max)));
        if (a == address(this) || a == alice || a == bob || a == spender || a == address(token)) {
            a = address(uint160(a) + 1);
        }
        if (a.code.length != 0) a = makeAddr(vm.toString(raw));
    }

    function testFuzz_SupplyMintsToWhoeverDeploys(address rawDeployer) public {
        address deployer = _external(rawDeployer);
        vm.prank(deployer);
        BIT created = new BIT();
        assertEq(created.totalSupply(), SUPPLY);
        assertEq(created.balanceOf(deployer), SUPPLY);
        assertEq(created.balanceOf(address(this)), 0);
        assertEq(created.balanceOf(tx.origin), tx.origin == deployer ? SUPPLY : 0);
    }

    function testFuzz_EveryDeploymentIsIndependent(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        BIT other = new BIT();
        assertTrue(other.transfer(alice, amount));
        assertEq(other.balanceOf(alice), amount);
        assertEq(token.balanceOf(alice), 0, "a transfer on one deployment moved balance on another");
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply() + other.totalSupply(), 2 * SUPPLY);
    }

    function testFuzz_RoundTripRestoresBothBalances(address rawTo, uint256 rawAmount) public {
        address to = _external(rawTo);
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        vm.prank(to);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(to), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SplitTransfersEqualOneTransfer(uint256 rawFirst, uint256 rawSecond) public {
        uint256 first = bound(rawFirst, 0, SUPPLY);
        uint256 second = bound(rawSecond, 0, SUPPLY - first);
        BIT other = new BIT();
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, second));
        assertTrue(other.transfer(alice, first + second));
        assertEq(token.balanceOf(alice), other.balanceOf(alice));
        assertEq(token.balanceOf(address(this)), other.balanceOf(address(this)));
        assertEq(token.balanceOf(alice) + token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_ChainedTransfersConserveSupplyAcrossActors(
        uint256 seedA,
        uint256 seedB,
        uint256 seedC,
        uint256 rawFirst,
        uint256 rawSecond
    ) public {
        address a = _actor(seedA);
        address b = _actor(seedB);
        address c = _actor(seedC);
        uint256 first = bound(rawFirst, 0, token.balanceOf(address(this)));
        assertTrue(token.transfer(a, first));
        uint256 second = bound(rawSecond, 0, token.balanceOf(a));
        vm.prank(a);
        assertTrue(token.transfer(b, second));
        uint256 third = bound(rawFirst ^ rawSecond, 0, token.balanceOf(b));
        vm.prank(b);
        assertTrue(token.transfer(c, third));
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob)
                + token.balanceOf(spender),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SelfTransferOfAnyAffordableAmountIsANoOp(uint256 rawHeld, uint256 rawAmount) public {
        uint256 held = bound(rawHeld, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, held);
        assertTrue(token.transfer(alice, held));
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
    }

    function testFuzz_SelfTransferAboveBalanceReverts(uint256 rawHeld, uint256 rawExcess) public {
        uint256 held = bound(rawHeld, 0, SUPPLY);
        uint256 amount = held + bound(rawExcess, 1, type(uint256).max - held);
        assertTrue(token.transfer(alice, held));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount)
        );
        vm.prank(alice);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), held);
    }

    function testFuzz_InfiniteAllowanceBoundary(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        uint256 nearlyInfinite = type(uint256).max - 1;

        assertTrue(token.approve(spender, nearlyInfinite));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), nearlyInfinite - amount, "max-1 is finite");

        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY - amount));
        assertEq(token.allowance(address(this), spender), type(uint256).max, "max is unlimited");
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFuzz_InfiniteAllowanceSurvivesRepeatedSpends(uint256 rawA, uint256 rawB) public {
        uint256 a = bound(rawA, 0, SUPPLY);
        uint256 b = bound(rawB, 0, SUPPLY - a);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, a));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, b));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), a);
        assertEq(token.balanceOf(bob), b);
    }

    function testFuzz_ExactAllowanceSpendsToZeroAndNoFurther(uint256 rawAllowed) public {
        uint256 allowed = bound(rawAllowed, 1, SUPPLY);
        assertTrue(token.approve(spender, allowed));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, allowed));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), allowed);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), allowed);
    }

    function testFuzz_PartialSpendsNeverExceedTheOriginalAllowance(
        uint256 rawAllowed,
        uint256 rawFirst,
        uint256 rawSecond
    ) public {
        uint256 allowed = bound(rawAllowed, 0, SUPPLY);
        uint256 first = bound(rawFirst, 0, allowed);
        uint256 second = bound(rawSecond, 0, allowed - first);
        assertTrue(token.approve(spender, allowed));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, first));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, second));
        assertEq(token.allowance(address(this), spender), allowed - first - second);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), first + second);

        // The allowance is checked before the balance, so one wei past it always fails on allowance.
        uint256 remaining = allowed - first - second;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, remaining, remaining + 1
            )
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, remaining + 1);
        assertEq(token.allowance(address(this), spender), remaining);
    }

    function testFuzz_ApproveIsLastWriteWinsNotAdditive(uint256 first, uint256 second) public {
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(address(this), spender), first);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second, "re-approving the same value changed it");
        assertEq(token.allowance(spender, address(this)), 0, "an approval leaked in the other direction");
        assertEq(token.allowance(address(this), alice), 0, "an approval leaked to another spender");
    }

    function testFuzz_ApprovalsAreIndependentPerSpenderAndOwner(uint256 a, uint256 b) public {
        assertTrue(token.approve(spender, a));
        vm.prank(alice);
        assertTrue(token.approve(spender, b));
        assertEq(token.allowance(address(this), spender), a);
        assertEq(token.allowance(alice, spender), b);
        assertEq(token.allowance(address(this), alice), 0);
        assertEq(token.allowance(spender, address(this)), 0);
    }

    function testFuzz_OnlyTheOwnerCanRaiseAnAllowance(address rawStranger, uint256 rawAmount) public {
        address stranger = _external(rawStranger);
        uint256 amount = bound(rawAmount, 1, type(uint256).max);
        // A stranger approving on their own account grants nothing from this account.
        vm.prank(stranger);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), stranger, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_EmptyAccountCannotSendAnyPositiveAmount(address rawFrom, uint256 rawAmount) public {
        address from = _external(rawFrom);
        uint256 amount = bound(rawAmount, 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, 0, amount)
        );
        vm.prank(from);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(from), 0);
    }

    function testFuzz_AllowanceDoesNotCreateBalance(uint256 rawHeld, uint256 rawExcess) public {
        uint256 held = bound(rawHeld, 0, SUPPLY - 1);
        uint256 amount = held + bound(rawExcess, 1, SUPPLY - held);
        assertTrue(token.transfer(alice, held));
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    function testFuzz_FailedTransferLeavesEveryoneUntouched(
        uint256 rawHeld,
        uint256 rawExcess,
        uint256 seedTo
    ) public {
        uint256 held = bound(rawHeld, 0, SUPPLY);
        uint256 amount = held + bound(rawExcess, 1, type(uint256).max - held);
        address to = _actor(seedTo);
        assertTrue(token.transfer(alice, held));
        uint256 toBefore = token.balanceOf(to);
        uint256 deployerBefore = token.balanceOf(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount)
        );
        vm.prank(alice);
        token.transfer(to, amount);

        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.balanceOf(address(this)), deployerBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransfersToAnyNonZeroAddressSucceedIncludingContracts(uint256 rawAmount, uint256 which)
        public
    {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        address[3] memory contracts = [address(token), address(this), address(vm)];
        address to = contracts[which % contracts.length];
        uint256 before = token.balanceOf(to);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), to, amount);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), to == address(this) ? SUPPLY : before + amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferToZeroRevertsForAnyAmount(uint256 amount) public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_ApproveZeroSpenderRevertsForAnyAmount(uint256 amount, uint256 seedOwner) public {
        address owner = _actor(seedOwner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        assertEq(token.allowance(owner, address(0)), 0);
    }

    function testFuzz_NobodyCanSpendFromTheZeroAddress(uint256 amount, uint256 seedSpender) public {
        address who = _actor(seedSpender);
        // A zero amount passes the allowance check but the allowance rewrite rejects the zero owner;
        // any other amount fails on the allowance the zero address never granted.
        bytes memory expected = amount == 0
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, who, 0, amount);
        vm.expectRevert(expected);
        vm.prank(who);
        token.transferFrom(address(0), who, amount);
        assertEq(token.balanceOf(who), who == address(this) ? SUPPLY : 0);
    }

    function testFuzz_MetadataIsConstantAcrossActivity(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertTrue(token.approve(spender, amount));
        assertEq(token.name(), "BIT");
        assertEq(token.symbol(), "BIT");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
