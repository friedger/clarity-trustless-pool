// Happy-path reward distribution: two stackers each receive their
// proportional share of a 100_000_000-sat (1 sBTC) reward, and 1 sat of dust
// is left behind in the contract.
//
// Setup (seeded via addEvalCode, bypassing the full delegate-stx/commit flow):
//   alice stacked = 250_000_000_000_000 uSTX
//   bob   stacked = 500_000_000_000_000 uSTX
//   total-stacked = 750_000_000_000_000 uSTX
//   reward-id = 1, cycle = TARGET_CYCLE, amount = 100_000_000 sats
//
// Expected shares:
//   alice = floor(100_000_000 * 250 / 750) = 33_333_333
//   bob   = floor(100_000_000 * 500 / 750) = 66_666_666
//   dust  = 1 sat (remains in reward-balance and
//                  remaining-sbtc-by-reward-id[1])

import { SimulationBuilder } from "stxer";
import {
  ALICE,
  BOB,
  PAYOUT_CONTRACT,
  blockHeightForCycle,
  deployFirstParty,
  distributeRewards,
  seedLocked,
  seedReward,
} from "./reward-distribution-helpers";

const TARGET_CYCLE = 118;
const REWARD_ID = 1;
const REWARD_AMOUNT = 100_000_000;

async function main() {
  const builder = SimulationBuilder.new().useBlockHeight(
    blockHeightForCycle(TARGET_CYCLE + 1)
  );

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
    .addContractCall(distributeRewards(ALICE, 0, ALICE, REWARD_ID))
    .addContractCall(distributeRewards(BOB, 0, BOB, REWARD_ID))
    // Replays are idempotent no-ops: (ok true) with no ft_transfer_event.
    .addContractCall(distributeRewards(ALICE, 1, ALICE, REWARD_ID))
    .addVarRead(PAYOUT_CONTRACT, "reward-balance")
    .addMapRead(
      PAYOUT_CONTRACT,
      "remaining-sbtc-by-reward-id",
      "0x0100000000000000000000000000000001"
    );

  const id = await builder.run();
  console.log(
    `stxer.xyz/simulations/mainnet/${id} — happy path, expect 1 sat dust`
  );
}

main().catch(console.error);
