// Unhappy path: distribute-rewards is called for a user who is NOT in the
// pool's per-cycle `locked { cycle, stacker }` snapshot. Their share
// computes to 0 (default-to u0 on a none map-get), so:
//   - (ok true) is returned,
//   - no ft_transfer_event fires,
//   - no `distributions` entry is written,
//   - the per-reward ledger and reward-balance are unchanged.
//
// Replays remain no-ops by construction.

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

// Charlie is not seeded into the locked map.
const CHARLIE = "SP3K8BC0PPEVCV7NZ6QSRWPQ2JE9E5B6N3PA0KBR9";

async function main() {
  const builder = SimulationBuilder.new().useBlockHeight(
    blockHeightForCycle(TARGET_CYCLE + 1)
  );

  deployFirstParty(builder);

  // Only alice is in the snapshot; bob is seeded for realistic total-stacked.
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
    .addContractCall(distributeRewards(CHARLIE, 0, CHARLIE, REWARD_ID))
    // Replay: still a no-op.
    .addContractCall(distributeRewards(CHARLIE, 1, CHARLIE, REWARD_ID))
    .addVarRead(PAYOUT_CONTRACT, "reward-balance");

  const id = await builder.run();
  console.log(
    `stxer.xyz/simulations/mainnet/${id} — no-stake user: zero-share no-op`
  );
}

main().catch(console.error);
