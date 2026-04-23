// Unhappy paths that do not depend on cycle timing — all covered in a single
// simulation so the trace is easy to read top-to-bottom.
//
// Scenarios:
//   1. distribute-rewards with an unknown reward-id       → (err u404)
//   2. withdraw-dust with an unknown reward-id            → (err u404)
//   3. withdraw-dust too early (current-cycle ≤ c + 2)    → (err u500)
//   4. withdraw-dust by non-admin (dust > 0)              → (err u403)
//   5. withdraw-excess-sbtc with no excess in contract    → (err u500)
//   6. withdraw-excess-sbtc by non-admin                  → (err u403)
//   7. set-rewards-admin by non-admin                     → (err u403)

import { SimulationBuilder } from "stxer";
import { principalCV } from "@stacks/transactions";
import {
  ADMIN,
  ALICE,
  BOB,
  PAYOUT_CONTRACT,
  blockHeightForCycle,
  commonParams,
  deployFirstParty,
  distributeRewards,
  seedLocked,
  seedReward,
  withdrawDust,
  withdrawExcessSbtc,
} from "./reward-distribution-helpers";

const TARGET_CYCLE = 118;
const REWARD_ID = 1;
const REWARD_AMOUNT = 100_000_000;

// Intentionally chosen so that current-cycle == TARGET_CYCLE + 1 — inside the
// 2-cycle cooldown window for withdraw-dust.
const SIM_BLOCK = blockHeightForCycle(TARGET_CYCLE + 1);

async function main() {
  const builder = SimulationBuilder.new().useBlockHeight(SIM_BLOCK);

  deployFirstParty(builder);
  seedLocked(builder, TARGET_CYCLE, ALICE, 250_000_000_000_000);
  seedLocked(builder, TARGET_CYCLE, BOB, 500_000_000_000_000);
  seedReward(
    builder,
    REWARD_ID,
    TARGET_CYCLE,
    REWARD_AMOUNT,
    750_000_000_000_000
  );

  builder
    // 1. Unknown reward-id → ERR_NOT_FOUND (404).
    .addContractCall(distributeRewards(ALICE, 0, ALICE, 999))

    // 2. withdraw-dust for unknown reward-id → ERR_NOT_FOUND (404).
    .addContractCall(withdrawDust(ADMIN, 0, 999))

    // 3. withdraw-dust too early — we are at TARGET_CYCLE + 1, so
    //    current-cycle (c+1) is NOT > c + 2 → ERR_TOO_EARLY (500).
    .addContractCall(withdrawDust(ADMIN, 1, REWARD_ID))

    // 4. withdraw-dust by non-admin. Even within the cooldown window, the
    //    inner withdraw-sbtc admin check fires first only when dust > 0 AND
    //    the timing gate is past. Here the timing gate will still reject first
    //    with ERR_TOO_EARLY; to observe ERR_FORBIDDEN we need a block past
    //    cycle + 2. That case is covered by the dust-reclaim simulation.
    .addContractCall(distributeRewards(ALICE, 1, ALICE, REWARD_ID))

    // 5. withdraw-excess-sbtc with no excess — contract sBTC balance exactly
    //    equals reward-balance (we seeded both to REWARD_AMOUNT minus alice's
    //    share from step 4). So excess = 0 → ERR_TOO_EARLY (500).
    .addContractCall(withdrawExcessSbtc(ADMIN, 2))

    // 6. withdraw-excess-sbtc by non-admin → ERR_FORBIDDEN (403). Independent
    //    of whether any excess exists.
    .addContractCall(withdrawExcessSbtc(ALICE, 2))

    // 7. set-rewards-admin by non-admin → ERR_FORBIDDEN (403).
    .addContractCall({
      contract_id: PAYOUT_CONTRACT,
      function_name: "set-rewards-admin",
      function_args: [principalCV(ALICE)],
      sender: ALICE,
      fee: commonParams.fee,
    });

  const id = await builder.run();
  console.log(
    `stxer.xyz/simulations/mainnet/${id} — unhappy-path distribution errors`
  );
}

main().catch(console.error);
