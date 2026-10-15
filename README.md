# BIT

BIT is a fixed-supply ERC-20 token. Its constructor mints **100,000,000 BIT**, with **18 decimals**, to the immediate deploying address in one mint. The production contract is [`src/BIT.sol`](src/BIT.sol).

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract identifier | `BIT` |
| Foundry artifact | `out/BIT.sol/BIT.json` |
| Token name / symbol | `BIT` / `BIT` |
| Decimals | `18` |
| Total supply in base units | `100000000000000000000000000` |
| Constructor arguments | None (`[]`) |
| Initial supply recipient | Constructor `msg.sender` |
| Application contracts | None |
| Compiler | Solidity `0.8.26` |
| EVM target | `cancun` |
| Optimizer | Enabled, 200 runs |
| Bytecode metadata hash | `none` |
| Target launch chain | Ethereum, chain ID `1` |

The constant `INITIAL_SUPPLY` is `100_000_000 * 10 ** 18`. There are no configurable token parameters, initializers, linked libraries, proxy contracts, or external constructor calls. The constructor requires no ETH.

Deploy the creation bytecode of `BIT`, without appended constructor arguments. When the launch factory creates the contract, that factory receives the entire supply; the transaction signer and requester receive nothing directly from the constructor. The factory is then responsible for the launch distribution. A direct deployment instead credits the direct deployer. Deploying through another helper credits that helper, so it must be able to transfer the supply.

The network's separate manifest and deployment steps handle `launch.json`, deployment, pool creation, and allocations. The token itself neither allocates reserves nor interacts with a DEX. The supplied launch policy distributes 10% through the distributor, 88% to pool liquidity, and 2% to the requester's remainder recipient; these are factory operations, not token constructor parameters. No transactions are broadcast by this project.

## Behavior and assumptions

The token uses the vendored OpenZeppelin Contracts v5.0.2 ERC-20 implementation without overriding transfer or approval behavior:

- Transfers deliver the exact requested amount. There are no transfer taxes, fees, rebases, blacklists, pauses, or holding restrictions.
- Anyone may transfer their own balance. A spender may transfer only an amount authorized by the holder's allowance.
- Successful `transfer`, `approve`, and `transferFrom` calls return `true`. Invalid calls revert with ERC-6093 custom errors.
- Zero-value transfers between nonzero addresses succeed and emit `Transfer`. Transfers to the zero address and approvals for the zero spender revert.
- Finite allowances decrease on `transferFrom`; `type(uint256).max` represents an unlimited allowance and is not decreased.
- `approve` replaces the allowance and emits `Approval`. This OpenZeppelin version does not emit `Approval` when `transferFrom` consumes allowance; integrations should read `allowance` for its current value.
- Self-transfers preserve balances. Delegated self-transfers still consume finite allowance.
- The constructor emits one `Transfer(address(0), deployer, INITIAL_SUPPLY)` event. There are no callable mint or burn functions after construction, so total supply remains constant.

There is no owner, administrator, upgrade mechanism, or privileged deployer role. The deployer has only the same rights as any other holder. The implementation makes no external calls during token operations and has no callbacks, oracles, timers, or backend dependencies.

## Build and test

Run from the repository root with Foundry and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x214c5f76627d885e998c1627b9aaae6b300f138d0acb05fc3dcf88efdd1bab34 forge test
forge fmt --check
```

All Solidity dependencies are ordinary files under `lib/`; no package installation, submodules, network access, environment values, RPC, or keys are needed by the tests. Foundry's seed variable above selects the assignment's reproducible fuzz input sequence; tests do not read or modify environment variables. The pinned compiler must already be installed for an offline build.

[`DEPENDENCIES.json`](DEPENDENCIES.json) records exact upstream commits and archive hashes. The OpenZeppelin subset includes ERC-20 and its complete import closure. The full forge-std `src/` directory is included for testing. Upstream license files accompany both dependencies. No downloaded binaries are included.

[`test/BIT.t.sol`](test/BIT.t.sol) covers metadata, the single constructor mint, CREATE2 factory deployment, exact distribution and purchase/sale token transfers, events, zero and self-transfers, full-balance transfers, approvals and revocation, finite and unlimited allowances, insufficient balances and allowances, failure rollback, zero addresses, and rejection of administrative/mint/burn selectors. Four fuzz properties each run 1,024 cases.

[`test/BIT.invariant.t.sol`](test/BIT.invariant.t.sol) exercises sequences of transfers, approvals, and delegated transfers among four holders. Two invariants compare every balance and allowance against an independent ledger and enforce conservation of the full supply. Each runs 128 sequences with up to 64 calls; unexpected handler reverts fail the run.

The local launch-flow test checks exact token movements, not actual Uniswap pricing or swaps. The supplied protected integration tests import the network's separate factory/pool test infrastructure and require its manifest-derived deployment inputs. Those dependencies and inputs are not included in this standalone token repository; the network verifier runs those integration checks separately.

## After launch

No token settings or administrative actions are required after deployment. The launch operator is responsible for deploying the approved artifact, distributing the factory-held supply, creating the pool, and verifying the published source and deployment parameters. Check the metadata, exact total supply, and constructor mint recipient against the deployment receipt.

Holders are responsible for wallet custody, recipient correctness, and spender approvals. Prefer approvals limited to the intended amount; an unlimited approval lets that spender move the holder's full present and future balance until revoked. To replace an existing nonzero allowance, first revoke it with `approve(spender, 0)`, wait for confirmation, and then set the new allowance. A spender may still spend an existing allowance before the revocation confirms.

There is no recovery or rescue function. Tokens sent to the BIT contract or another address unable to transfer them can become inaccessible without reducing `totalSupply`. There is no payable entry point for ETH and no way to withdraw forcibly received ETH. No administrator can reverse transfers, recover lost keys, or freeze balances.

The implementation review and validation scope are recorded in [`SECURITY.md`](SECURITY.md). Tests and this local review do not replace the network's independent review before release.
