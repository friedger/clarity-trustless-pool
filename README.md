# clarity-trustless-pool

Trustless stacking pool on Bitcoin L2 Stacks.

The Stacks blockchain's Proof of Transfer (PoX) consensus lets STX holders earn
Bitcoin rewards by stacking, and stacking pools let small holders participate.
In conventional pools, users have to trust the operator to forward rewards. A
**trustless stacking pool** removes that trust: delegation, commits, reward
custody, and reward distribution are handled by smart contracts that anyone
can drive.

## Key benefits

- **No custody risk** — STX never leave the user's wallet; they are locked in
  `pox-4` under a delegation the user can revoke.
- **Lower barrier** — users can join with ~0.01% of the cycle's total locked
  STX (~50 STX as of April 2026).
- **Automated rewards** — on-chain sBTC distribution, no trusted operator
  touching the funds.
- **Permissionless operations** — aggregation, deposit forwarding, and
  per-user distribution can be triggered by anyone (bots, the users
  themselves, friends and family).

## Risks

- **Smart contract bugs** — unintended behavior encoded in the contracts.
- **Dummy read-only helpers** — `get-total-stacked` and the test-mode
  `get-user-stacked` helpers are placeholders and must be replaced for
  production (see "Limitations" below).

## Architecture

Three first-party contracts participate in the flow, plus two external
dependencies:

### Contracts

1. **`pox4-self-service-multi-v2.clar`** — wraps `pox-4` delegation and
   stacking. Users call `delegate-stx` once; any principal can extend the
   user's lock with `delegate-stack-stx` / `delegate-stack-stx-many` after the
   half-cycle point. Tracks committed `reward-set-indices` per cycle and
   snapshots per-user locked amounts into a `locked` map keyed by
   `{ cycle, stacker }` so that payouts can read historical stakes without
   relying on `at-block` (which was removed in Clarity 5 / epoch 3.4).
   Permissioned admin operations: `set-pool-pox-address-active`,
   `set-active`, `set-reward-admin`, `set-stx-buffer`.

2. **`deposit-vault.clar`** — holds inbound sBTC rewards. `transfer` forwards
   the sBTC to the payout contract either during the prepare phase of a cycle
   or once the balance exceeds `INTERMED_MINIMUM` (0.1 sBTC). Permissionless.
   The vault's sBTC deposit address is registered as the pool's PoX reward
   address in `pox4-self-service-multi-v2`, so rewards land in the vault
   automatically.

3. **`payout-self-service-sbtc.clar`** — accepts rewards via `deposit-rewards`
   (permissionless; anyone with sBTC can top up) and distributes them to
   stackers in proportion to their locked STX for the reward's cycle.
   Admin-only maintenance: `withdraw-dust`, `withdraw-excess-sbtc`,
   `set-rewards-admin`.

### External dependencies

- `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token` — the sBTC SIP-010
  token.
- `SP000000000000000000002Q6VF78.pox-4` — the Stacks PoX-4 contract.
- `SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4.pox4-multi-pool-v1` — the
  existing multi-pool reference deployment used for parity testing.

## End-to-end flow (happy path)

See `docs/happy-path.md` for the off-chain binaries involved. On-chain, the
operation is:

1. Pool admin sets the pool's PoX address to the vault's sBTC deposit address
   via `set-pool-pox-address-active`.
2. User allows the pool contract as a contract-caller on `pox-4`, then calls
   `pox4-self-service-multi-v2.delegate-stx`. The contract revokes any
   previous delegation, re-delegates to itself, and locks the user's STX for
   one cycle (minus a small STX buffer for the revoke-delegation tx fee).
3. A bot (or anyone) calls `stack-aggregation-commit` before the prepare
   phase, producing a reward-set entry that `pox-4` will pay out to the
   vault's Bitcoin address.
4. Bitcoin block producers pay sBTC rewards to the vault.
5. Anyone calls `deposit-vault.transfer` during the prepare phase (or once
   the balance crosses `INTERMED_MINIMUM`), moving the sBTC into the payout
   contract via `payout-self-service-sbtc.deposit-rewards`.
6. Anyone calls `payout-self-service-sbtc.distribute-rewards(user, id)` or
   `distribute-rewards-many(users, id)` to stream each user's share.

Every step after the user's initial `delegate-stx` is permissionless — the
contract, not any operator, enforces correctness.

## Payout math and dust handling

A user's share of a reward is:

```
share = floor(reward_amount_sbtc * user_stacked / total_stacked)
```

This is pure integer truncation. Because shares are computed independently
per user (not "last user gets the remainder"), the sum of all shares is less
than or equal to the reward; the gap — at most `N - 1` sats for `N` users —
is **dust** that stays in the contract. Where it lives:

- `remaining-sbtc-by-reward-id[reward-id]` — per-reward ledger of unspent sBTC,
  decremented on every `distribute-rewards*` transfer.
- `reward-balance` — global reserve of reserved sBTC, decremented in
  lock-step.

After a **2-cycle cooldown** (`current-cycle > reward-cycle + 2`), the
rewards admin reclaims the dust via `withdraw-dust(reward-id)`. The cooldown
is there so stackers have time to claim; reclaimed dust is not
automatically redistributed.

sBTC transferred to the payout contract outside of `deposit-rewards` (for
example if a reward lands directly, or as a simple accounting mistake) is
recoverable at any time by the admin via `withdraw-excess-sbtc`. This
function can only move the unreserved surplus (`contract-balance -
reward-balance`); reserved rewards are protected.

## Limitations

- **Dummy aggregates.** `get-total-stacked` returns a hard-coded placeholder
  (`750_000_000_000_000` uSTX) via `get-total-stacked-dummy`, and a
  `get-total-stacked-testnet` variant reads from the pool contract. A real
  mainnet implementation must read the committed reward-set entries.
- **Zero-share users are a no-op.** If a user's share truncates to 0 (tiny
  stake vs. small reward), `distribute-reward-internal` fires no
  `ft_transfer_event` and does **not** write a `distributions` entry. Retries
  are harmless but keep producing 0 until either the reward grows or their
  stake does — which, for a given reward ID, will not happen.
- **Dust is not redistributed.** It is reclaimable by the admin after the
  2-cycle cooldown but never rolls into the next reward pool.
- **`withdraw-dust` retention.** The function decrements `reward-balance` but
  does not delete the `remaining-sbtc-by-reward-id` entry. The ledger entry
  is informational after a single successful reclaim; a second call is
  rejected by the `reserved-reward-balance >= unspent-sbtc` underflow guard.
- **`at-block` removed (Clarity 5 / SIP-042).** Historical state lookups are
  no longer possible. Per-user stacked amounts are instead snapshotted into
  the `locked` map in `pox4-self-service-multi-v2` at commit time.
- **Static caps.** `distribute-rewards-many` takes at most 200 principals;
  `pox-addr-indices` tracks at most 10 reward-set indices per cycle;
  `delegate-stack-stx-many` takes at most 30 users per call.
- **Admin blast radius.** A compromised `rewards-admin` can: rotate itself
  away, reclaim dust after cycle+2, pull excess sBTC, and (historically)
  front-run stackers for undistributed dust. Users claiming within the
  cycle+2 window are safe; unclaimed dust is not.
- **Delegation decrease.** The pool refuses to decrease a user's locked
  amount (`ERR_DECREASE_FORBIDDEN`); decreases require waiting one cycle for
  unlock, then re-delegating.

## Design choices

- **Permissionless distribution.** Anyone can trigger `distribute-rewards`
  for any user, including bots. The contract is the authority; operators are
  a convenience. The same applies to `deposit-rewards`, `deposit-vault.transfer`,
  and `stack-aggregation-commit`.
- **Independent per-user shares.** Keeping shares independent of calculation
  order (rather than "last user gets the remainder") makes distribution
  idempotent and replayable — a bot that hits a retry loop cannot overpay,
  underpay, or reorder claims. The cost is accepting a small, deterministic
  dust residue per reward.
- **Reserved / excess split.** `reward-balance` tracks reserved rewards and
  is isolated from the admin's `withdraw-excess-sbtc` path. This enforces a
  hard boundary between user funds and accidental or adversarial deposits.
- **Cooldown before dust reclaim.** Two full cycles elapse before
  `withdraw-dust` is allowed, which bounds the admin's ability to front-run
  legitimate claims.
- **Snapshot-based stacking ledger.** Because Clarity 5 removes `at-block`,
  per-user stakes are written into a `locked { cycle, stacker }` map at
  commit time, and `get-user-stacked(cycle, user)` reads from there. This
  trades a small extra write per commit for the loss of historical lookups.
- **Clarity 5 (epoch 3.4).** All first-party contracts are Clarity 5, using
  `as-contract?` and SIP-030 allowance grants.

## Testing

### Unit & integration tests (Vitest + Clarinet SDK)

```bash
pnpm install
pnpm test          # full suite
pnpm test:report   # + coverage + cost reports
pnpm test:watch    # re-runs on .ts / .clar edits
```

A single file: `npx vitest run tests/payout-self-service-sbtc.test.ts`.
Filter by test name: add `-t "calculate-share"`.

### Flow tests (Clarity, discovered via `@stacks/clarunit`)

Flow tests live in `contracts/tests/*_test.clar` and use comment
annotations to drive multi-sender scenarios:

```clarity
;; @name test the delegation flow
;; @format-ignore
(define-public (test-delegation)
  (begin
    ;; @caller deployer
    (unwrap! (contract-call? .pox4-self-service-multi-v2 set-pool-pox-address-active
      {version: 0x00, hashbytes: 0x7321b74e2b6a7e949e6c4ad313035b1665095017})
      (err u1000))
    ;; @caller wallet_1
    (unwrap! (contract-call? 'ST000000000000000000002AMW42H.pox-4
      allow-contract-caller .pox4-self-service-multi-v2 none)
      (err u2000))
    ;; More test steps...
    (ok true)
  )
)
```

They are registered as `*_test` entries in `Clarinet.toml` and loaded by the
one-liner `tests/clarunit.test.ts`.

### Devnet

Devnet deployments live under `deployments/` as numbered YAML plans; apply
them in order against a running `clarinet devnet start`:

```bash
clarinet devnet start
clarinet deployment apply deployments/0-init.yaml
clarinet deployment apply deployments/1-alice-delegate.devnet-plan.yaml
# ...
```

### Signature generation

PoX-4 aggregation-commit signatures for tests and scripts:

```bash
pnpm generate:signature    # runs src/signature.ts
```
