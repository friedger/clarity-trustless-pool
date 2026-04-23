import { tx } from "@stacks/clarinet-sdk";
import {
  expectOk,
  expectOkTrue,
} from "@stacks/clarunit/src/parser/test-helpers.ts";
import {
  boolCV,
  cvToString,
  listCV,
  noneCV,
  principalCV,
  uintCV,
} from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
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
describe("payout", () => {
  beforeEach(() => {
    let block = simnet.mineBlock([
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
        1000000000000000,
        123,
        alice,
      ),
    ]);
    // commit events
    console.log(cvToString(block[5].events[0].data.value));
    expectOkTrue(
      block,
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      "set-pox-address-active",
    );
    expectOk(block, POX4_SELF_SERVICE_MULTI_CONTRACT_NAME, "delegate-stx", 3);
    expectOk(block, POX4_SELF_SERVICE_MULTI_CONTRACT_NAME, "delegate-stx", 4);
    expectOk(
      block,
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      "stack-aggregation-commit",
      5,
    );
    // reward set index is 0
    expect(block[5].result).toBeOk(uintCV(0));
  });

  it("Ensure that anyone can deposit funds", () => {
    simnet.mineEmptyBlocks(2050); // move to prepare phase within end of cycle #1
    const currentCycle = simnet.callReadOnlyFn(
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      "current-pox-reward-cycle",
      [],
      deployer,
    );
    console.log("current cycle", currentCycle);

    const preparePhase = simnet.callReadOnlyFn(
      "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault",
      "in-prepare-phase",
      [],
      deployer,
    );
    console.log("prepare phase", preparePhase.result);

    let results = simnet.mineBlock([
      // 1: receive sbtc rewards to deposit vault
      tx.callPublicFn(
        "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token",
        "transfer",
        [
          uintCV(100_000_000),
          principalCV(alice),
          principalCV(
            "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault",
          ),
          noneCV(),
        ],
        alice,
      ),
      // 2: transfer from deposit vault to payout contract
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault",
        "transfer",
        [],
        bob,
      ),
      // 3: distribute rewards
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "distribute-rewards-many",
        [listCV([principalCV(alice)]), uintCV(1)],
        deployer,
      ),
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "distribute-rewards",
        [principalCV(alice), uintCV(1)],
        deployer,
      ),
    ]);

    console.log(
      "results",
      results.map((r: any) => r.events),
    );

    expectOkTrue(results, "sbtc-token", "transfer", 0);
    expectOk(results, "deposit-vault", "transfer", 1);
    expectOk(results, "payout-self-service-sbtc", "distribute-rewards", 2);
    expectOk(results, "", "", 3);
    expect(results[0].events[0].event).toBe("ft_transfer_event");
    expect(results[0].events[0].data.amount).toBe("100000000");
    expect(results[2].events[0].event).toBe("ft_transfer_event");
    expect(results[2].events[0].data.amount).toBe("2666"); // alice
    expect(results[3].events.length).toBe(0); // no sbtc transferred for second call
  });
});

// calculate-share is `floor(reward * user-stacked / total-stacked)` — pure
// integer truncation. The sum of per-user shares is therefore ≤ reward; the
// gap (up to N-1 sats for N users) is "dust" that stays in the contract.
//
// Where the dust lives afterwards:
//   - remaining-sbtc-by-reward-id[reward-id]: per-reward leftover ledger, decremented
//     by each user's share as they claim.
//   - reward-balance: global reserve, decremented by the same share on transfer.
//
// After a 2-cycle cooldown, the rewards admin reclaims the per-reward dust via
// withdraw-dust; sBTC that was transferred to the contract outside of
// deposit-rewards is recoverable at any time via withdraw-excess-sbtc. Neither
// is automatically redistributed to stackers.
//
// Because share is computed independently per user (not as "last user takes
// the remainder"), the final sat cannot be fully allocated when
//   (reward * user-stacked) mod total-stacked != 0
// for more than one user. This is a deliberate trade-off for idempotent,
// order-independent distribution.
describe("payout rounding", () => {
  const payout =
    "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";

  const share = (reward: number, user: number, total: number) =>
    simnet.callReadOnlyFn(
      payout,
      "calculate-share",
      [uintCV(reward), uintCV(user), uintCV(total)],
      deployer,
    ).result;

  it("calculate-share truncates via integer division", () => {
    // 100_000_000 sats split 1/3 : 2/3 → 33_333_333 and 66_666_666.
    // Exact values are 33_333_333.33… and 66_666_666.66… — both truncate down.
    // Dust: 100_000_000 - (33_333_333 + 66_666_666) = 1 sat left in contract.
    expect(
      share(100_000_000, 250_000_000_000_000, 750_000_000_000_000),
    ).toBeUint(33_333_333);
    expect(
      share(100_000_000, 500_000_000_000_000, 750_000_000_000_000),
    ).toBeUint(66_666_666);
    expect(33_333_333 + 66_666_666).toBe(100_000_000 - 1);

    // Reward fully divisible by total → no dust.
    expect(share(300, 100, 300)).toBeUint(100);
    expect(share(300, 200, 300)).toBeUint(200);
  });

  it("calculate-share rounds small shares down to zero", () => {
    // A user holding 1 / 1_000_000 of the pool gets 0 sats from a 999_999-sat
    // reward, and 1 sat only once the reward reaches 1_000_000.
    // distribute-reward-internal short-circuits when share is 0: no
    // ft_transfer_event AND no distributions-map entry is written, so the
    // call remains a no-op on every retry.
    expect(share(999_999, 1, 1_000_000)).toBeUint(0);
    expect(share(1_000_000, 1, 1_000_000)).toBeUint(1);
  });

  it("calculate-share computes the product before the division", () => {
    // (10_000_000_000 * 10) / 3 = 33_333_333_333 — confirms multiplication
    // happens first, so precision is only lost in the final floor step.
    // If division happened first, the intermediate result would be 33_333_333_330
    expect(share(10_000_000_000, 10, 3)).toBeUint(33_333_333_333);
  });
});

// These tests cover the dust-reclaim and excess-recovery paths. They do NOT
// set up any stacking — the paths under test are independent of the
// pox4-self-service-multi-v2 snapshot. Rewards are registered via
// deposit-rewards (which is permissionless) and then either left undistributed
// (so the entire reward is "dust" once the cooldown passes) or bypassed
// entirely (direct sBTC transfers become "excess").
describe("withdraw-dust", () => {
  const payout =
    "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";
  const sbtc = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
  const REWARD = 100_000_000;

  // Register a reward for cycle 0. After cycle 0's reward phase ends
  // (burn-block-height > cycle_length - prepare_length = 2000), deposit-rewards
  // succeeds. Leaves the whole reward undistributed so it all counts as "dust".
  const seedReward = () => {
    simnet.mineEmptyBlocks(2050);
    const setup = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "deposit-rewards",
        [uintCV(REWARD), uintCV(0)],
        alice
      ),
    ]);
    expect(setup[0].result).toBeOk(uintCV(1));
    return 1; // reward-id
  };

  it("admin reclaims the full undistributed remainder after the cycle+2 cooldown", () => {
    const rewardId = seedReward();

    // Advance past cycle 2 (cycle+2 = 2, withdraw-dust requires current > 2).
    // Each cycle is 2100 blocks; we already mined 2051 so we need another ~4250
    // to cross into cycle 3.
    simnet.mineEmptyBlocks(4300);

    const balanceBefore = simnet.callReadOnlyFn(
      payout,
      "get-reward-balance",
      [],
      deployer
    ).result;
    expect(balanceBefore).toBeUint(REWARD);

    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "withdraw-dust",
        [uintCV(rewardId)],
        deployer
      ),
    ]);
    expect(block[0].result).toBeOk(boolCV(true));
    expect(block[0].events[0].event).toBe("ft_transfer_event");
    expect(block[0].events[0].data.amount).toBe(REWARD.toString());
    expect(block[0].events[0].data.recipient).toBe(deployer);

    const balanceAfter = simnet.callReadOnlyFn(
      payout,
      "get-reward-balance",
      [],
      deployer
    ).result;
    expect(balanceAfter).toBeUint(0);
  });

  it("too-early: current-cycle ≤ reward-cycle + 2 fails with ERR_TOO_EARLY", () => {
    const rewardId = seedReward();
    // Don't advance further — we're still in cycle 0 (or just past into 1).
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "withdraw-dust",
        [uintCV(rewardId)],
        deployer
      ),
    ]);
    expect(block[0].result).toBeErr(uintCV(500)); // ERR_TOO_EARLY
  });

  it("unknown reward-id fails with ERR_NOT_FOUND", () => {
    // No reward registered at id 42.
    simnet.mineEmptyBlocks(10_000);
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "withdraw-dust",
        [uintCV(42)],
        deployer
      ),
    ]);
    expect(block[0].result).toBeErr(uintCV(404)); // ERR_NOT_FOUND
  });

  it("non-admin rejected once dust > 0 (via inner withdraw-sbtc admin check)", () => {
    const rewardId = seedReward();
    simnet.mineEmptyBlocks(4300);
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "withdraw-dust",
        [uintCV(rewardId)],
        alice // not the admin
      ),
    ]);
    expect(block[0].result).toBeErr(uintCV(403)); // ERR_FORBIDDEN
  });

  it("double-call: second withdraw-dust hits the reward-balance underflow guard", () => {
    const rewardId = seedReward();
    simnet.mineEmptyBlocks(4300);
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "withdraw-dust",
        [uintCV(rewardId)],
        deployer
      ),
      tx.callPublicFn(
        payout,
        "withdraw-dust",
        [uintCV(rewardId)],
        deployer
      ),
    ]);
    expect(block[0].result).toBeOk(boolCV(true));
    expect(block[0].events.length).toBe(2);
    expect(block[0].events[0].event).toBe("ft_transfer_event");
    expect(block[0].events[1].event).toBe("print_event");
    // Second call: reserved-reward-balance (now 0).
    expect(block[1].result).toBeOk(boolCV(true));
    expect(block[1].events.length).toBe(0);
  });
});

describe("withdraw-excess-sbtc", () => {
  const payout =
    "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";
  const sbtc = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";

  const directTransfer = (amount: number, from: string) =>
    tx.callPublicFn(
      sbtc,
      "transfer",
      [uintCV(amount), principalCV(from), principalCV(payout), noneCV()],
      from
    );

  it("admin reclaims sBTC that was transferred to the contract outside deposit-rewards", () => {
    const AMOUNT = 5_000_000;
    simnet.mineBlock([directTransfer(AMOUNT, alice)]);

    const reservedBefore = simnet.callReadOnlyFn(
      payout,
      "get-reward-balance",
      [],
      deployer
    ).result;
    expect(reservedBefore).toBeUint(0);

    const block = simnet.mineBlock([
      tx.callPublicFn(payout, "withdraw-excess-sbtc", [], deployer),
    ]);
    expect(block[0].result).toBeOk(boolCV(true));
    expect(block[0].events[0].event).toBe("ft_transfer_event");
    expect(block[0].events[0].data.amount).toBe(AMOUNT.toString());
    expect(block[0].events[0].data.recipient).toBe(deployer);

    // reward-balance is untouched by withdraw-excess-sbtc.
    const reservedAfter = simnet.callReadOnlyFn(
      payout,
      "get-reward-balance",
      [],
      deployer
    ).result;
    expect(reservedAfter).toBeUint(0);
  });

  it("no excess present (contract balance ≤ reserved) fails with ERR_TOO_EARLY", () => {
    // Fresh contract: balance = 0, reserved = 0. No excess.
    const block = simnet.mineBlock([
      tx.callPublicFn(payout, "withdraw-excess-sbtc", [], deployer),
    ]);
    expect(block[0].result).toBeErr(uintCV(500)); // ERR_TOO_EARLY
  });

  it("non-admin rejected with ERR_FORBIDDEN", () => {
    simnet.mineBlock([directTransfer(1_000_000, alice)]);
    const block = simnet.mineBlock([
      tx.callPublicFn(payout, "withdraw-excess-sbtc", [], alice),
    ]);
    expect(block[0].result).toBeErr(uintCV(403)); // ERR_FORBIDDEN
  });

  it("reserved rewards are protected: only the unreserved portion is withdrawable", () => {
    const RESERVED = 3_000_000;
    const EXTRA = 1_500_000;

    simnet.mineEmptyBlocks(2050);
    // Register a reward so that RESERVED is tied up in reward-balance.
    simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "deposit-rewards",
        [uintCV(RESERVED), uintCV(0)],
        alice
      ),
    ]);
    expect(
      simnet.callReadOnlyFn(payout, "get-reward-balance", [], deployer).result
    ).toBeUint(RESERVED);

    // Now send extra sBTC directly to the contract (bypassing deposit-rewards).
    simnet.mineBlock([directTransfer(EXTRA, alice)]);

    const block = simnet.mineBlock([
      tx.callPublicFn(payout, "withdraw-excess-sbtc", [], deployer),
    ]);
    expect(block[0].result).toBeOk(boolCV(true));
    expect(block[0].events[0].data.amount).toBe(EXTRA.toString());

    // Reserved reward-balance is still RESERVED, proving user funds are safe.
    expect(
      simnet.callReadOnlyFn(payout, "get-reward-balance", [], deployer).result
    ).toBeUint(RESERVED);
  });
});

describe("deposit-rewards", () => {
  const payout =
    "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";

  it("is permissionless: a non-admin account with sBTC can register rewards", () => {
    simnet.mineEmptyBlocks(2050);
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "deposit-rewards",
        [uintCV(1_000_000), uintCV(0)],
        alice // not the admin; this is the bot-style call from deposit-vault
      ),
    ]);
    expect(block[0].result).toBeOk(uintCV(1));
  });

  it("before the end of the target cycle's reward phase, fails with ERR_TOO_EARLY", () => {
    // No block mining: we're at burn-block-height ~1, well before cycle 0's
    // reward-phase end (~2000). deposit-rewards for cycle 0 must be refused.
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "deposit-rewards",
        [uintCV(1_000_000), uintCV(0)],
        alice
      ),
    ]);
    expect(block[0].result).toBeErr(uintCV(500)); // ERR_TOO_EARLY
  });
});

describe("distribute-rewards error paths", () => {
  const payout =
    "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";

  it("unknown reward-id fails with ERR_NOT_FOUND", () => {
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "distribute-rewards",
        [principalCV(alice), uintCV(42)],
        deployer
      ),
    ]);
    expect(block[0].result).toBeErr(uintCV(404)); // ERR_NOT_FOUND
  });
});

describe("set-rewards-admin", () => {
  const payout =
    "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc";

  it("non-admin cannot rotate the admin", () => {
    const block = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "set-rewards-admin",
        [principalCV(alice)],
        alice
      ),
    ]);
    expect(block[0].result).toBeErr(uintCV(403)); // ERR_FORBIDDEN
  });

  it("after rotation, the new principal is admin and the old principal is not", () => {
    // Deployer is the default admin (set to tx-sender at contract-init).
    const rotate = simnet.mineBlock([
      tx.callPublicFn(
        payout,
        "set-rewards-admin",
        [principalCV(alice)],
        deployer
      ),
    ]);
    expect(rotate[0].result).toBeOk(boolCV(true));

    // Old admin (deployer) can no longer withdraw excess.
    simnet.mineBlock([
      tx.callPublicFn(
        "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token",
        "transfer",
        [
          uintCV(500_000),
          principalCV(bob),
          principalCV(payout),
          noneCV(),
        ],
        bob
      ),
    ]);
    const oldAdminAttempt = simnet.mineBlock([
      tx.callPublicFn(payout, "withdraw-excess-sbtc", [], deployer),
    ]);
    expect(oldAdminAttempt[0].result).toBeErr(uintCV(403));

    // New admin (alice) succeeds.
    const newAdminAttempt = simnet.mineBlock([
      tx.callPublicFn(payout, "withdraw-excess-sbtc", [], alice),
    ]);
    expect(newAdminAttempt[0].result).toBeOk(boolCV(true));
  });
});
