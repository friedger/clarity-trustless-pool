// Happy path for `withdraw-dust` — run at a block height that is past the
// 2-cycle cooldown (current-cycle > reward-cycle + 2), so the admin is
// allowed to reclaim the residual sBTC.
//
// The simulation seeds a reward for TARGET_CYCLE that was only partially
// distributed: alice claimed her 33_333_333 sats; bob never claimed his
// 66_666_666 sats (either the bot missed him or he doesn't care). After the
// cooldown window, the admin reclaims:
//   dust = remaining-sbtc-by-reward-id[1] = 66_666_667
// (that's bob's unclaimed 66_666_666 plus the natural 1-sat rounding dust).
//
// Also runs a second call to prove double-reclaim is rejected by the
// `reserved-reward-balance >= unspent-sbtc` underflow guard.

import { SimulationBuilder } from "stxer";
import {
  ADMIN,
  ALICE,
  BOB,
  PAYOUT_CONTRACT,
  blockHeightForCycle,
  deployFirstParty,
  distributeRewards,
  seedLocked,
  seedReward,
  withdrawDust,
} from "./reward-distribution-helpers";

const TARGET_CYCLE = 118;
const REWARD_ID = 1;
const REWARD_AMOUNT = 100_000_000;
// At cycle c + 3: current-cycle > c + 2 → withdraw-dust is allowed.
const SIM_BLOCK = blockHeightForCycle(TARGET_CYCLE + 3);

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
    // alice claims her share — 33_333_333 sats. bob does not.
    .addContractCall(distributeRewards(ALICE, 0, ALICE, REWARD_ID))

    // Admin reclaims the residual: bob's 66_666_666 + 1 sat of rounding = 66_666_667.
    .addContractCall(withdrawDust(ADMIN, 0, REWARD_ID))

    // Double-reclaim is rejected with ERR_UNEXPECTED (999): after the first
    // call reward-balance is 0, but the per-reward ledger still holds 66_666_667.
    .addContractCall(withdrawDust(ADMIN, 1, REWARD_ID))

    .addVarRead(PAYOUT_CONTRACT, "reward-balance")
    .addMapRead(
      PAYOUT_CONTRACT,
      "remaining-sbtc-by-reward-id",
      "0x0100000000000000000000000000000001"
    );

  const id = await builder.run();
  console.log(
    `stxer.xyz/simulations/mainnet/${id} — dust reclaim past cycle + 2`
  );
}

main().catch(console.error);
