// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BIT} from "../src/BIT.sol";

/// @notice Drives the token with a mix of valid operations and attacks that must fail: overdrawn
/// transfers, spends past an allowance, transfers to and from the zero address, privileged selectors
/// from the deployer and strangers, and ether. Every rejected call is checked for the exact error
/// and for leaving state untouched; every accepted call is mirrored in an independent ledger that
/// also covers fresh fuzzed recipients and the token contract itself as a sink.
contract BITAdversaryHandler is Test {
    uint256 internal constant SUPPLY = 100_000_000 * 10 ** 18;
    uint256 internal constant MAX_TOUCHED = 24;

    BIT public immutable token;
    address public immutable deployer;
    address[] public actors;
    address[] public touched;
    mapping(address => bool) public isTouched;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    uint256 public ghostAccepted;
    uint256 public ghostRejected;
    uint256 public ghostMoved;
    uint256 public ghostAdminAttempts;

    string[22] internal privileged = [
        "mint(address,uint256)",
        "mint(uint256)",
        "mint()",
        "issue(uint256)",
        "setOwner(address)",
        "transferOwnership(address)",
        "upgradeTo(address)",
        "initialize(address)",
        "unpause()",
        "setMinter(address)",
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

    constructor(BIT token_, address deployer_, address[] memory actors_) {
        token = token_;
        deployer = deployer_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            _touch(actors_[i]);
        }
        _touch(address(token_));
        expectedBalance[deployer_] = SUPPLY;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function _touch(address a) internal {
        if (!isTouched[a]) {
            isTouched[a] = true;
            touched.push(a);
        }
    }

    function _sender(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev A recipient: usually an actor, sometimes the token contract (a sink nobody can drain),
    /// sometimes a fresh address that joins the ledger.
    function _recipient(uint256 seed) internal returns (address) {
        uint256 pick = seed % (actors.length + 2);
        if (pick < actors.length) return actors[pick];
        if (pick == actors.length) return address(token);
        if (touched.length >= MAX_TOUCHED) return touched[seed % touched.length];
        address fresh = address(uint160(uint256(keccak256(abi.encode("BIT fresh recipient", seed)))));
        _touch(fresh);
        return fresh;
    }

    function _snapshot(address a, address b) internal view returns (bytes32) {
        return keccak256(abi.encode(token.balanceOf(a), token.balanceOf(b), token.totalSupply()));
    }

    // ---------------------------------------------------------------- accepted paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _sender(fromSeed);
        address to = _recipient(toSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ghostAccepted++;
        ghostMoved += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        address spender = _sender(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        ghostAccepted++;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address owner = _sender(ownerSeed);
        address spender = _sender(spenderSeed);
        address to = _recipient(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 amount = bound(rawAmount, 0, allowed < available ? allowed : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        ghostAccepted++;
        ghostMoved += amount;
    }

    // ---------------------------------------------------------------- rejected paths

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 rawExcess) external {
        address from = _sender(fromSeed);
        address to = _recipient(toSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = held + bound(rawExcess, 1, type(uint256).max - held);
        bytes32 before = _snapshot(from, to);
        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "an overdrawn transfer succeeded");
        } catch (bytes memory err) {
            assertEq(
                err,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
            );
        }
        assertEq(_snapshot(from, to), before, "a rejected transfer changed state");
        ghostRejected++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _sender(fromSeed);
        bytes32 before = _snapshot(from, address(0));
        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "a transfer to the zero address succeeded");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
        assertEq(_snapshot(from, address(0)), before, "a rejected transfer changed state");
        ghostRejected++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _sender(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            assertTrue(false, "an approval for the zero spender succeeded");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        assertEq(token.allowance(owner, address(0)), 0);
        ghostRejected++;
    }

    function transferFromOverAllowance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 rawExcess
    ) external {
        address owner = _sender(ownerSeed);
        address spender = _sender(spenderSeed);
        address to = _recipient(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 held = expectedBalance[owner];
        bytes memory expected;
        uint256 amount;
        if (allowed == type(uint256).max) {
            // Unlimited allowance: the only wall left is the owner's balance.
            amount = held + bound(rawExcess, 1, type(uint256).max - held);
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount);
        } else {
            amount = allowed + bound(rawExcess, 1, type(uint256).max - allowed);
            expected = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount
            );
        }
        bytes32 before = _snapshot(owner, to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            assertTrue(false, "a delegated transfer past its limit succeeded");
        } catch (bytes memory err) {
            assertEq(err, expected);
        }
        assertEq(_snapshot(owner, to), before, "a rejected delegated transfer changed state");
        assertEq(
            token.allowance(owner, spender), allowed, "a rejected delegated transfer changed the allowance"
        );
        ghostRejected++;
    }

    function transferFromZeroHolder(uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address spender = _sender(spenderSeed);
        address to = _recipient(toSeed);
        // A zero amount is rejected when the allowance is rewritten for the zero owner; any other
        // amount fails on the allowance the zero address never granted.
        bytes memory expected = amount == 0
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount);
        bytes32 before = _snapshot(address(0), to);
        vm.prank(spender);
        try token.transferFrom(address(0), to, amount) {
            assertTrue(false, "a transfer from the zero address succeeded");
        } catch (bytes memory err) {
            assertEq(err, expected);
        }
        assertEq(_snapshot(address(0), to), before, "a rejected transfer changed state");
        ghostRejected++;
    }

    /// @dev A privileged selector, tried from the deployer (the most plausibly trusted address) and
    /// from an arbitrary actor, with a victim and a large amount as arguments.
    function privilegedCall(uint256 which, uint256 callerSeed, uint256 victimSeed) external {
        string memory signature = privileged[which % privileged.length];
        address victim = _sender(victimSeed);
        address caller = _sender(callerSeed);
        bytes memory data = abi.encodeWithSignature(signature, victim, type(uint128).max);
        uint256 victimBefore = token.balanceOf(victim);

        vm.prank(deployer);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, signature);
        vm.prank(caller);
        (ok,) = address(token).call(data);
        assertFalse(ok, signature);

        assertEq(token.balanceOf(victim), victimBefore, signature);
        assertEq(token.totalSupply(), SUPPLY, signature);
        ghostAdminAttempts++;
    }

    function sendEther(uint256 callerSeed, uint256 rawValue) external {
        address caller = _sender(callerSeed);
        uint256 value = bound(rawValue, 1, 1_000 ether);
        vm.deal(caller, value);
        vm.deal(address(this), value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        vm.prank(caller);
        (ok,) = address(token).call{value: value}(abi.encodeWithSelector(token.transfer.selector, caller, 0));
        assertFalse(ok, "a non-payable function accepted ether");
        assertEq(address(token).balance, 0);
        assertEq(caller.balance, value);
        assertEq(address(this).balance, value);
        ghostRejected++;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BITAdversarialInvariantTest is Test {
    uint256 internal constant SUPPLY = 100_000_000 * 10 ** 18;

    BIT internal token;
    BITAdversaryHandler internal handler;
    address internal deployer;
    address[] internal actors;

    function setUp() public {
        deployer = makeAddr("deployer");
        actors.push(deployer);
        for (uint256 i = 1; i < 6; ++i) {
            actors.push(makeAddr(string.concat("holder ", vm.toString(i))));
        }
        // Deploy as the launch factory would: the whole supply lands on msg.sender, nobody else.
        vm.prank(deployer);
        token = new BIT();
        handler = new BITAdversaryHandler(token, deployer, actors);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = BITAdversaryHandler.transfer.selector;
        selectors[1] = BITAdversaryHandler.approve.selector;
        selectors[2] = BITAdversaryHandler.transferFrom.selector;
        selectors[3] = BITAdversaryHandler.transferOverBalance.selector;
        selectors[4] = BITAdversaryHandler.transferToZero.selector;
        selectors[5] = BITAdversaryHandler.approveZeroSpender.selector;
        selectors[6] = BITAdversaryHandler.transferFromOverAllowance.selector;
        selectors[7] = BITAdversaryHandler.transferFromZeroHolder.selector;
        selectors[8] = BITAdversaryHandler.privilegedCall.selector;
        selectors[9] = BITAdversaryHandler.sendEther.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The supply is fixed at what the constructor minted: nothing mints, nothing burns.
    function invariant_SupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    /// @dev Every account the sequence could have reached holds exactly what the ledger says, and
    /// together they hold the whole supply: nothing leaked to an address nobody sent to.
    function invariant_TouchedBalancesMatchLedgerAndSumToSupply() public view {
        uint256 count = handler.touchedCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            address a = handler.touched(i);
            uint256 balance = token.balanceOf(a);
            assertEq(balance, handler.expectedBalance(a));
            assertLe(balance, SUPPLY);
            sum += balance;
        }
        assertEq(sum, SUPPLY);
    }

    /// @dev Addresses outside the ledger hold nothing: the zero address, the harness, the handler.
    function invariant_UntouchedAddressesHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(address(token).balance, 0);
    }

    /// @dev Tokens sent to the token contract are a sink: they count toward the supply and never leave.
    function invariant_TokenContractIsASink() public view {
        assertEq(token.balanceOf(address(token)), handler.expectedBalance(address(token)));
    }

    /// @dev Allowances are exactly what owners set, less what was spent; nobody else wrote one.
    function invariant_AllowancesMatchLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j])
                );
            }
            assertEq(token.allowance(actors[i], address(0)), 0);
            assertEq(token.allowance(actors[i], address(handler)), 0);
            assertEq(token.allowance(address(0), actors[i]), 0);
        }
    }

    /// @dev The deployer is just a holder: what it has is the supply minus what it sent, never more.
    function invariant_DeployerHoldsOnlyWhatItKept() public view {
        assertEq(token.balanceOf(deployer), handler.expectedBalance(deployer));
        assertLe(token.balanceOf(deployer), SUPPLY);
    }
}
