import { tx } from "@hirosystems/clarinet-sdk";
import {
  expectOk,
  expectOkTrue,
} from "@stacks/clarunit/src/parser/test-helpers.ts";
import {
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
        alice
      ),
      allowContractCaller(
        deployer + "." + POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
        undefined,
        bob
      ),
      delegateStx(200_000_000_000_000, alice),
      delegateStx(100_000_000_000_000, bob),

      stackAggregationCommit(
        0,
        "0xee088eb40553ca5cddcd7eb18a48f76b5047bfa3b0a3da60446d69226d345c0a49a5a709e74a7a21933fce837e5fee86caaca2dbc4f42391d7710380ad023caf00",
        "0x03cd2cfdbd2ad9332828a7a13ef62cb999e063421c708e863a7ffed71fb61c88c9",
        1000000000000000,
        123,
        alice
      ),
    ]);
    // commit events
    console.log(cvToString(block[5].events[0].data.value));
    expectOkTrue(
      block,
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      "set-pox-address-active"
    );
    expectOk(block, POX4_SELF_SERVICE_MULTI_CONTRACT_NAME, "delegate-stx", 3);
    expectOk(block, POX4_SELF_SERVICE_MULTI_CONTRACT_NAME, "delegate-stx", 4);
    expectOk(
      block,
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      "stack-aggregation-commit",
      5
    );
    // reward set index is 0
    expect(block[5].result).toBeOk(uintCV(0));
  });
  it("Ensure that admin can allocate funds", () => {
    simnet.mineEmptyBlocks(2050);
    let block = simnet.mineBlock([
      tx.callPublicFn(
        "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token",
        "transfer",
        [
          uintCV(100_000_000),
          principalCV(alice),
          principalCV(
            "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc"
          ),
          noneCV(),
        ],
        alice
      ),
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "allocate-funds",
        [uintCV(100_000_000), uintCV(1)],
        deployer
      ),
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "distribute-rewards",
        [principalCV(alice), uintCV(1)],
        deployer
      ),
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "distribute-rewards-many",
        [listCV([principalCV(bob)]), uintCV(1)],
        deployer
      ),
    ]);

    expectOkTrue(block, "sbtc-token", "transfer");
    expectOk(block, "payout-self-service-sbtc", "allocate-funds", 1);
    expectOk(block, "payout-self-service-sbtc", "distribute-reward", 2);
    expectOk(block, "payout-self-service-sbtc", "distribute-reward-many", 3);
    console.log(block[2].events);
    console.log(block[3].events);
    expect(block[2].events[0].event).toBe("ft_transfer_event");
    expect(block[2].events[0].data.amount).toBe("33333333"); // alice
    expect(block[3].events[0].event).toBe("ft_transfer_event");
    expect(block[3].events[0].data.amount).toBe("66666666"); // bob
  });

  it("Ensure that anyone can deposit funds", () => {
    simnet.mineEmptyBlocks(2050); // move to prepare phase within end of cycle #1
    const currentCycle = simnet.callReadOnlyFn(
      "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.pox4-self-service-multi",
      "current-pox-reward-cycle",
      [],
      deployer
    );
    console.log("current cycle", currentCycle);

    const preparePhase = simnet.callReadOnlyFn(
      "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault",
      "in-prepare-phase",
      [],
      deployer
    );
    console.log("prepare phase", preparePhase.result);

    let block = simnet.mineBlock([
      // 0: change reward admin
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "set-rewards-admin",
        [
          principalCV(
            "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault"
          ),
        ],
        deployer
      ),
      // 1: receive sbtc rewards to deposit vault
      tx.callPublicFn(
        "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token",
        "transfer",
        [
          uintCV(100_000_000),
          principalCV(alice),
          principalCV(
            "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault"
          ),
          noneCV(),
        ],
        alice
      ),
      // 2: transfer from deposit vault to payout contract
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.deposit-vault",
        "transfer",
        [],
        bob
      ),
      // 3: distribute rewards
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "distribute-rewards-many",
        [listCV([principalCV(alice)]), uintCV(1)],
        deployer
      ),
      tx.callPublicFn(
        "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc",
        "distribute-rewards",
        [principalCV(alice), uintCV(1)],
        deployer
      ),
    ]);

    console.log(2, block[2]);
    console.log(3, block[3]);
    console.log(4, block[4]);

    expectOkTrue(block, "payout-self-service-sbtc", "set-rewards-admin");
    expectOkTrue(block, "sbtc-token", "transfer", 1);
    expectOk(block, "deposit-vault", "transfer", 2);
    expectOk(block, "payout-self-service-sbtc", "distribute-rewards", 3);
    expectOk(block, "", "", 4);
    expect(block[2].events[0].event).toBe("ft_transfer_event");
    expect(block[2].events[0].data.amount).toBe("100000000");
    expect(block[3].events[0].event).toBe("ft_transfer_event");
    expect(block[3].events[0].data.amount).toBe("33333333"); // alice
    expect(block[4].events.length).toBe(0); // no sbtc transferred for second call
  });
});
