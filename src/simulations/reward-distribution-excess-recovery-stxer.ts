// Happy and unhappy paths for `withdraw-excess-sbtc`.
//
// The payout contract reserves sBTC via deposit-rewards into `reward-balance`.
// Any sBTC that lands in the contract outside of that path (accidental
// transfer, stray rewards) is "excess" — the admin can recover it without
// touching reserved funds.
//
// This simulation:
//   1. Seeds a reward of 5_000_000 sats → reward-balance = 5_000_000.
//   2. Mints an extra 2_500_000 sats to the payout contract directly (as if
//      someone transferred sBTC by mistake).
//   3. Non-admin calls withdraw-excess-sbtc   → (err u403) ERR_FORBIDDEN.
//   4. Admin calls withdraw-excess-sbtc       → transfers 2_500_000 to admin,
//                                               reward-balance untouched.
//   5. Admin calls withdraw-excess-sbtc again → (err u500) ERR_TOO_EARLY
//                                               (no excess remains).

import { SimulationBuilder } from "stxer";
import {
  ADMIN,
  ALICE,
  BOB,
  PAYOUT_CONTRACT,
  SBTC,
  blockHeightForCycle,
  deployFirstParty,
  seedLocked,
  seedReward,
  withdrawExcessSbtc,
} from "./reward-distribution-helpers";

const TARGET_CYCLE = 118;
const REWARD_ID = 1;
const RESERVED = 5_000_000;
const STRAY = 2_500_000;
const SIM_BLOCK = blockHeightForCycle(TARGET_CYCLE + 1);

async function main() {
  const builder = SimulationBuilder.new().useBlockHeight(SIM_BLOCK);

  deployFirstParty(builder);
  seedLocked(builder, TARGET_CYCLE, ALICE, 250_000_000_000_000);
  seedLocked(builder, TARGET_CYCLE, BOB, 500_000_000_000_000);
  seedReward(builder, REWARD_ID, TARGET_CYCLE, RESERVED, 750_000_000_000_000);

  // Mint additional sBTC directly to the payout contract — this is the
  // "stray" balance that deposit-rewards never reserved.
  builder.addEvalCode(
    SBTC,
    `(ft-mint? sbtc-token u${STRAY} '${PAYOUT_CONTRACT})`
  );

  builder
    .addContractCall(withdrawExcessSbtc(ALICE, 0)) // non-admin → 403
    .addContractCall(withdrawExcessSbtc(ADMIN, 0)) // admin → ok, transfers STRAY
    .addContractCall(withdrawExcessSbtc(ADMIN, 1)) // no more excess → 500
    .addVarRead(PAYOUT_CONTRACT, "reward-balance");

  const id = await builder.run();
  console.log(
    `stxer.xyz/simulations/mainnet/${id} — excess recovery: reserved funds are isolated`
  );
}

main().catch(console.error);
