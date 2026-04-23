# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Install dependencies with `pnpm install` (this project uses pnpm, see `pnpm-lock.yaml`).

- `pnpm test` — run the full Vitest suite (TypeScript tests + Clarity flow tests via clarunit)
- `pnpm test:report` — same, plus coverage and cost reports (`lcov.info`, `costs-reports.json`)
- `pnpm test:watch` — re-runs `test:report` whenever a `.ts` or `.clar` file changes
- `pnpm generate:signature` — runs `src/signature.ts` to produce a PoX-4 aggregation-commit signature
- `pnpm test:stxer` — runs the stxer simulation in `src/simulations/change-pox-address-stxer.ts`

Run a single TS test file: `npx vitest run tests/payout-self-service-sbtc.test.ts`. Filter by test name with `-t "name"`.

Devnet deployments live in `deployments/` as numbered YAML plans. Apply them in order against a running `clarinet devnet start`:

```
clarinet deployment apply deployments/0-init.yaml
clarinet deployment apply deployments/1-alice-delegate.devnet-plan.yaml
# ...
```

## Architecture

Three Clarity 3 contracts implement a trustless, non-custodial PoX-4 stacking pool where sBTC rewards are distributed by smart contract rather than a pool operator:

- **`pox4-self-service-multi.clar`** — wraps `SP000000000000000000002Q6VF78.pox-4`. Users call `delegate-stx`; the contract revokes, delegates, and stacks in one call. After half a cycle has elapsed, anyone (bots, friends) can extend stacking for existing stackers via `delegate-stack-stx`. Supports up to 10 signers per cycle via `pox-addr-indices`. The pool's PoX reward address is set by a reward admin with `set-pool-pox-address-active` and **is the sBTC deposit address of the `deposit-vault` contract** — this is what makes rewards land in the vault.
- **`deposit-vault.clar`** — holds sBTC until cycle end. `transfer` forwards the balance to `payout-self-service-sbtc` either during the prepare phase or once the balance exceeds `intermed-minimum` (0.1 sBTC). Permissionless; designed to be triggered by bots.
- **`payout-self-service-sbtc.clar`** — receives sBTC via `deposit-rewards`, tracks per-cycle `total-stacked`, and distributes pro-rata to stackers. Also permissionless.

The **sBTC token contract address is hardcoded** to `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token` inside the `.clar` sources — if you re-target a different sBTC deployment you must edit the contracts, not just `Clarinet.toml`.

The operational flow documented in `docs/happy-path.md` relies on two off-chain binaries (`spox` for sBTC notifications, a pool binary for signer setup and commits). Every on-chain step is permissionless, so bots are an implementation convenience, not a trust dependency.

## Tests

Two test systems run inside the same Vitest process (`pool: "forks"`, `singleFork: true` — simnet state would collide otherwise):

1. **TypeScript/Vitest tests** in `tests/*.test.ts` drive simnet via `@stacks/clarinet-sdk` (the former `@hirosystems/clarinet-sdk`). Shared helpers live in `tests/clients/` (one wrapper per contract) and `tests/utils.ts`. `simnet` is available as a global because `vitest-environment-clarinet` injects it.
2. **Clarity flow tests** in `contracts/tests/*_test.clar` are loaded through the one-line entrypoint `tests/clarunit.test.ts` (`clarunit(simnet)`). `@stacks/clarunit` discovers `define-public` functions named `test-*` and uses comment annotations `;; @name`, `;; @caller <account>`, `;; @format-ignore` to drive multi-sender scenarios. These contracts are registered as `*_test` entries in `Clarinet.toml`.

When adding new test contracts, they must be registered in `Clarinet.toml` under `[contracts.<name>_test]` or clarunit will not see them.

## Off-chain code (`src/`)

- `src/signature.ts` — PoX-4 aggregation-commit signature generator (used both as a tool and for reference in flow tests)
- `src/deposit-address.ts` / `src/deposit-requests.ts` — sBTC deposit script + address construction (taproot). Tested in `tests/deposit-requests.test.ts`.
- `src/simulations/` — stxer-based simulations of real mainnet/testnet state

The repo depends on `pox-4` and `sbtc-token` as Clarinet requirements; you do not need to vendor those contracts locally.
