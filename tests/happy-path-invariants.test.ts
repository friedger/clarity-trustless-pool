// Scripted happy-path regression that exercises delegate-stx → commit →
// deposit → distribute → dust, asserting every `invariant-*` read-only on the
// payout contract at each checkpoint. Complements the random Rendezvous fuzz
// by providing a deterministic trace that hits the full state machine — which
// pure-random exploration rarely manages within 200 runs.
//
// Each checkpoint re-runs the complete invariant suite, so a regression in any
// invariant-related accounting (or the payout/vault cross-contract invariant)
// surfaces with a precise step label.

import { tx } from "@stacks/clarinet-sdk";
import {
  listCV,
  noneCV,
  principalCV,
  trueCV,
  uintCV,
} from "@stacks/transactions";
import { describe, expect, it } from "vitest";
import { allowContractCaller } from "./clients/pox-4-client.ts";
import {
  delegateStx,
  POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
  setPoxAddressActive,
  stackAggregationCommit,
} from "./clients/pox4-self-service-multi-client.ts";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const alice = accounts.get("wallet_2")!;
const bob = accounts.get("wallet_3")!;

const PAYOUT = "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";
const VAULT = "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";

const PAYOUT_INVARIANTS = [
  "invariant-reward-balance-matches-remaining",
  "invariant-distributed-matches-distributions",
  "invariant-user-stake-sum-le-total",
  "invariant-sbtc-conservation",
  "invariant-reward-balance-leq-sbtc-balance",
  "invariant-distribution-leq-share",
  "invariant-distribution-leq-amount",
  "invariant-distribution-implies-stacked",
  "invariant-reward-balance-leq-system-sbtc",
];

const POOL_INVARIANTS = [
  "invariant-locked-leq-delegated",
  "invariant-pox-addr-indices-capped",
  "invariant-deployer-remains-admin",
  "invariant-active-has-pox-address",
];

function assertAllInvariants(label: string) {
  for (const fn of PAYOUT_INVARIANTS) {
    const { result } = simnet.callReadOnlyFn(PAYOUT, fn, [], deployer);
    expect(result, `${label}: ${fn}`).toStrictEqual(trueCV());
  }
  for (const fn of POOL_INVARIANTS) {
    const { result } = simnet.callReadOnlyFn(
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      fn,
      [],
      deployer,
    );
    expect(result, `${label}: ${fn}`).toStrictEqual(trueCV());
  }
}

describe("happy-path invariants", () => {
  it("holds across delegate → commit → deposit → distribute → dust", () => {
    assertAllInvariants("initial");

    // Step 1: admin activates pool, both users authorise the pool as their
    // pox-4 caller and delegate STX. Commit the aggregated amount.
    const setup = simnet.mineBlock([
      setPoxAddressActive("mr1iPkD9N3RJZZxXRk7xF9d36gffa6exNC", deployer),
      allowContractCaller(
        deployer + "." + POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
        undefined,
        alice,
      ),
      allowContractCaller(
        deployer + "." + POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
        undefined,
        bob,
      ),
      delegateStx(200_000_000_000_000, alice),
      delegateStx(100_000_000_000_000, bob),
      stackAggregationCommit(
        0,
        "0xee088eb40553ca5cddcd7eb18a48f76b5047bfa3b0a3da60446d69226d345c0a49a5a709e74a7a21933fce837e5fee86caaca2dbc4f42391d7710380ad023caf00",
        "0x03cd2cfdbd2ad9332828a7a13ef62cb999e063421c708e863a7ffed71fb61c88c9",
        1_000_000_000_000_000,
        123,
        alice,
      ),
    ]);
    expect(setup[5].result).toBeOk(uintCV(0));
    assertAllInvariants("after delegate+commit");

    // Step 2: advance to prepare phase so the vault will forward.
    simnet.mineEmptyBlocks(2050);
    assertAllInvariants("after mining to prepare phase");

    // Step 3: sBTC rewards arrive at the vault, get forwarded to payout,
    // then are distributed pro-rata.
    const rewardFlow = simnet.mineBlock([
      tx.callPublicFn(
        SBTC,
        "transfer",
        [
          uintCV(100_000_000),
          principalCV(alice),
          principalCV(VAULT),
          noneCV(),
        ],
        alice,
      ),
      tx.callPublicFn(VAULT, "transfer", [], bob),
      tx.callPublicFn(
        PAYOUT,
        "distribute-rewards-many",
        [listCV([principalCV(alice), principalCV(bob)]), uintCV(1)],
        deployer,
      ),
    ]);
    expect(rewardFlow[0].result).toBeOk(trueCV());
    expect(rewardFlow[2].result).toBeOk(trueCV());
    assertAllInvariants("after deposit+distribute");

    // Step 4: re-distribute to the same users — must be idempotent (no
    // second transfer events, no accounting change).
    const reDistribute = simnet.mineBlock([
      tx.callPublicFn(
        PAYOUT,
        "distribute-rewards",
        [principalCV(alice), uintCV(1)],
        deployer,
      ),
    ]);
    expect(reDistribute[0].events.length).toBe(0);
    assertAllInvariants("after idempotent re-distribute");

    // Step 5: advance past cycle+2 so withdraw-dust becomes legal, then
    // admin sweeps leftover dust from the reward.
    simnet.mineEmptyBurnBlocks(2100 * 3);
    const dust = simnet.mineBlock([
      tx.callPublicFn(PAYOUT, "withdraw-dust", [uintCV(1)], deployer),
    ]);
    expect(dust[0].result).toBeOk(trueCV());
    assertAllInvariants("after withdraw-dust");
  });
});
