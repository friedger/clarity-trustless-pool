// Shared building blocks for the reward-distribution stxer simulations.
//
// Each simulation deploys fresh copies of the three first-party contracts on
// top of real mainnet state (at a chosen `block_height`) and then seeds the
// pool's per-cycle `locked` map and the payout contract's reward bookkeeping
// directly via `addEvalCode`. That bypasses the full delegate-stx → commit
// flow — which would otherwise require real pox-4 signers and delegation — and
// lets the simulations focus on the distribute / withdraw paths.
//
// Run a simulation with:
//   npx tsx src/simulations/reward-distribution-happy-stxer.ts
// The script prints a stxer.xyz URL when the simulation completes.

import {
  AnchorMode,
  PostConditionMode,
  principalCV,
  uintCV,
} from "@stacks/transactions";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

export const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";

// Replace with real principals for your stxer run if desired. The simulator
// does not verify signatures, so these can be arbitrary valid c32
// mainnet principals.
export const DEPLOYER = "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4";
export const ADMIN = DEPLOYER;
export const ALICE = "SP34EBMKMRR6SXX65GRKJ1FHEXV7AGHJ2D8ASQ5M3";
export const BOB = "SP2C2YFP12AJZB4MABJBAJ55XECVS7E4PMMZ89YZR";

export const POOL_CONTRACT_NAME = "pox4-self-service-multi-v2";
export const PAYOUT_CONTRACT_NAME = "payout-self-service-sbtc";
export const VAULT_CONTRACT_NAME = "deposit-vault";

export const POOL_CONTRACT = `${DEPLOYER}.${POOL_CONTRACT_NAME}`;
export const PAYOUT_CONTRACT = `${DEPLOYER}.${PAYOUT_CONTRACT_NAME}`;
export const VAULT_CONTRACT = `${DEPLOYER}.${VAULT_CONTRACT_NAME}`;

export const commonParams = {
  publicKey: "",
  postConditionMode: PostConditionMode.Allow,
  anchorMode: AnchorMode.Any,
  fee: 10_000,
};

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");
const readContract = (name: string) =>
  fs.readFileSync(path.join(repoRoot, "contracts", `${name}.clar`), "utf8");

// Deploy all three first-party contracts under a single deployer. Pool must
// deploy first (payout and vault both reference it).
export function deployFirstParty(builder: any) {
  return builder
    .addContractDeploy({
      contract_name: POOL_CONTRACT_NAME,
      source_code: readContract(POOL_CONTRACT_NAME),
      deployer: DEPLOYER,
      clarity_version: 5,
    })
    .addContractDeploy({
      contract_name: PAYOUT_CONTRACT_NAME,
      source_code: readContract(PAYOUT_CONTRACT_NAME),
      deployer: DEPLOYER,
      clarity_version: 5,
    })
    .addContractDeploy({
      contract_name: VAULT_CONTRACT_NAME,
      source_code: readContract(VAULT_CONTRACT_NAME),
      deployer: DEPLOYER,
      clarity_version: 5,
    });
}

// Seed the pool's per-cycle `locked { cycle, stacker }` snapshot. This is
// what pox4-self-service-multi-v2.get-user-stacked reads from — writing it
// directly means we don't have to go through delegate-stx and an actual
// pox-4 aggregation commit.
export function seedLocked(
  builder: any,
  cycle: number,
  user: string,
  amount: number
) {
  return builder.addEvalCode(
    POOL_CONTRACT,
    `(map-set locked { cycle: u${cycle}, stacker: '${user} } u${amount})`
  );
}

// Seed the payout contract's reward bookkeeping so distribute-rewards can run
// without us having to call deposit-rewards (which would require the caller to
// hold `amount` sBTC). The three variables must be kept consistent:
//   - rewards[reward-id] carries the cycle + reward amount + total-stacked,
//   - remaining-sbtc-by-reward-id[reward-id] is the per-reward unspent ledger,
//   - reward-balance is the global reserve (incremented by `amount` each time).
// We also set the sBTC balance of the payout contract so the SIP-010 transfer
// in distribute-reward-internal actually has funds to move.
export function seedReward(
  builder: any,
  rewardId: number,
  cycle: number,
  amount: number,
  totalStacked: number
) {
  return builder
    .addEvalCode(
      PAYOUT_CONTRACT,
      `(map-set rewards u${rewardId} { cycle: u${cycle}, amount-sbtc: u${amount}, total-stacked: u${totalStacked} })`
    )
    .addEvalCode(
      PAYOUT_CONTRACT,
      `(map-set remaining-sbtc-by-reward-id u${rewardId} u${amount})`
    )
    .addEvalCode(
      PAYOUT_CONTRACT,
      `(var-set reward-balance (+ (var-get reward-balance) u${amount}))`
    )
    .addEvalCode(
      PAYOUT_CONTRACT,
      `(var-set last-reward-id u${rewardId})`
    )
    .addEvalCode(
      SBTC,
      `(ft-mint? sbtc-token u${amount} '${PAYOUT_CONTRACT})`
    );
}

export function distributeRewards(
  sender: string,
  nonce: number,
  user: string,
  rewardId: number
) {
  return {
    contract_id: PAYOUT_CONTRACT,
    function_name: "distribute-rewards",
    function_args: [principalCV(user), uintCV(rewardId)],
    nonce,
    sender,
    ...commonParams,
  };
}

export function withdrawDust(sender: string, nonce: number, rewardId: number) {
  return {
    contract_id: PAYOUT_CONTRACT,
    function_name: "withdraw-dust",
    function_args: [uintCV(rewardId)],
    nonce,
    sender,
    ...commonParams,
  };
}

export function withdrawExcessSbtc(sender: string, nonce: number) {
  return {
    contract_id: PAYOUT_CONTRACT,
    function_name: "withdraw-excess-sbtc",
    function_args: [],
    nonce,
    sender,
    ...commonParams,
  };
}

export function depositRewards(
  sender: string,
  nonce: number,
  amount: number,
  cycle: number
) {
  return {
    contract_id: PAYOUT_CONTRACT,
    function_name: "deposit-rewards",
    function_args: [uintCV(amount), uintCV(cycle)],
    nonce,
    sender,
    ...commonParams,
  };
}

// Asserts the simulation is reading real mainnet state at/after the cycle we
// are distributing for — distribute-rewards does not itself gate on cycle
// timing, but it's cleaner to pick a block height after the target cycle
// finished so the reward would have been legitimately depositable.
export const MAINNET_CYCLE_LENGTH = 2100;
export const MAINNET_FIRST_BURN = 666_050;
export const blockHeightForCycle = (cycle: number) =>
  MAINNET_FIRST_BURN + cycle * MAINNET_CYCLE_LENGTH + 100;
