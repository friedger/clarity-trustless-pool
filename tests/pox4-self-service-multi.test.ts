import { expectOkTrue } from "@stacks/clarunit/src/parser/test-helpers.ts";
import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import { allowContractCaller, getCycleLength } from "./clients/pox-4-client.js";
import { poxAddrFP } from "./constants.ts";
import {
  expectOkLockingResult,
  expectPartialStackedByCycle,
  expectTotalStackedByCycle,
} from "./utils.ts";
import {
  delegateStackStx,
  delegateStx,
  POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
  poxPoolSelfServiceMultiContract,
  setPoxAddressActive,
} from "./clients/pox4-self-service-multi-client.ts";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet_1 = accounts.get("wallet_1")!;
const wallet_2 = accounts.get("wallet_2")!;
describe("multi pool", () => {
  beforeEach(() => {
    let block = simnet.mineBlock([
      setPoxAddressActive(
        "bc1qs0kkdpsrzh3ngqgth7mkavlwlzr7lms2zv3wxe",
        deployer
      ),
    ]);
    expectOkTrue(
      block,
      POX4_SELF_SERVICE_MULTI_CONTRACT_NAME,
      "set-pox-address-active"
    );
  });
  it("Ensure that users can delegate", () => {
    let block = simnet.mineBlock([
      allowContractCaller(poxPoolSelfServiceMultiContract, undefined, wallet_1),
      allowContractCaller(poxPoolSelfServiceMultiContract, undefined, wallet_2),
      delegateStx(20_000_000_000_100, wallet_1),
      delegateStx(2_100_000, wallet_2),
    ]);

    // check allow contract caller
    expectOkTrue(block, "pox-4", "allow-contract-caller", 0);
    expectOkTrue(block, "pox-4", "allow-contract-caller", 1);

    expectOkLockingResult(block[2], {
      lockAmount: 19_999_999_000_100,
      stacker: wallet_1,
      unlockBurnHeight: 2100,
    });
    expectOkLockingResult(block[3], {
      lockAmount: 1_100_000,
      stacker: wallet_2,
      unlockBurnHeight: 2100,
    });

    // commit did not yet happen
    // commit needs to be called by pool operator with signer key
    expectPartialStackedByCycle(poxAddrFP, 1, 20_000_000_100_100, deployer);
    expectTotalStackedByCycle(1, 0, undefined, deployer);
  });

  it("See that in simnet user can't increase amount for next cycle", () => {
    const { CYCLE } = getCycleLength();
    // current cycle is cycle 0

    // delegate 2 stx for cycle 1
    let block = simnet.mineBlock([
      allowContractCaller(poxPoolSelfServiceMultiContract, undefined, wallet_1),
      delegateStx(2_000_000, wallet_1),
    ]);

    expectOkTrue(block, "pox-4", "allow-contract-caller", 0);
    expectOkLockingResult(block[1], {
      lockAmount: 1_000_000,
      stacker: wallet_1,
      unlockBurnHeight: 2100,
    });

    expectPartialStackedByCycle(poxAddrFP, 1, 1_000_000, deployer);
    expectTotalStackedByCycle(1, 0, undefined, deployer);

    simnet.mineEmptyBlocks(CYCLE);

    // increase delegation to 3 stx for cycle 2
    block = simnet.mineBlock([delegateStx(3_000_000, wallet_1)]);
    expectOkLockingResult(block[0], {
      lockAmount: 2_000_000,
      stacker: wallet_1,
      unlockBurnHeight: 3150,
    });
  });

  it("See that in simnet user can extend for next cycle for any user", () => {
    const { CYCLE, HALF_CYCLE } = getCycleLength();

    expect(simnet.burnBlockHeight).toBe(3);

    let block = simnet.mineBlock([
      allowContractCaller(poxPoolSelfServiceMultiContract, undefined, wallet_1),
      delegateStx(2_000_000, wallet_1),
    ]);

    expectOkTrue(block, "pox-4", "allow-contract-caller", 0);
    expectOkLockingResult(block[1], {
      lockAmount: 1_000_000,
      stacker: wallet_1,
      unlockBurnHeight: 2100,
    });
    expectPartialStackedByCycle(poxAddrFP, 1, 1_000_000, deployer);
    expectPartialStackedByCycle(poxAddrFP, 2, undefined, deployer);

    // advance to middle of next cycle
    simnet.mineEmptyBlocks(CYCLE + HALF_CYCLE - 3);
    expect(simnet.burnBlockHeight).toBe(CYCLE + HALF_CYCLE);

    // try to extend to cycle 2 early
    block = simnet.mineBlock([delegateStackStx(wallet_1, wallet_2)]);
    expect(block.length).toBe(1);
    expect(block[0].result).toBeErr(Cl.uint(500)); // too early

    simnet.mineEmptyBlocks(1);
    expect(simnet.burnBlockHeight).toBe(CYCLE + HALF_CYCLE + 1);

    // extend to cycle 2
    block = simnet.mineBlock([delegateStackStx(wallet_1, wallet_2)]);
    expect(simnet.burnBlockHeight).toBe(CYCLE + HALF_CYCLE + 1);

    expectOkLockingResult(block[0], {
      lockAmount: 1_000_000,
      stacker: wallet_1,
      unlockBurnHeight: 3150,
    });
    expectPartialStackedByCycle(poxAddrFP, 2, 1_000_000, deployer);
  });
});
