// Rendezvous pre-dialer for payout-self-service-sbtc.
//
// Raw fast-check args drift into ranges that cannot reach the interesting
// state transitions (reward-id billions, cycle 2^30, amount near u128 max).
// Clamp them to small, plausible ranges so calls to distribute-rewards,
// withdraw-dust, deposit-rewards, etc. actually land in the happy path
// often enough to exercise the accounting invariants.
//
// Only `clarityValueArguments` is mutable from a dialer. Callers and the
// auto-mined burn-block advance are controlled by Rendezvous itself.
//
// Rendezvous loads this file via require(); package.json has "type": "module"
// so this must be a .cjs file.

const { Cl } = require("@stacks/transactions");

// Keep these small. reward-id starts at 1 and grows by one per successful
// deposit-rewards, so a handful of slots covers typical runs. Cycles 0..4
// are reachable once Rendezvous has mined a few thousand burn blocks.
const MAX_REWARD_ID = 5n;
const MAX_CYCLE = 4n;
const MAX_AMOUNT = 10_000_000n; // 0.1 sBTC

const toBig = (cv) => BigInt(cv.value);

const clampUint = (cv, max) => Cl.uint(toBig(cv) % (max + 1n));
const clampUintMin1 = (cv, max) => Cl.uint((toBig(cv) % max) + 1n);

const rewriters = {
  "deposit-rewards": (args) => [
    Cl.uint((toBig(args[0]) % MAX_AMOUNT) + 1n),
    clampUint(args[1], MAX_CYCLE),
  ],
  "distribute-rewards": (args) => [args[0], clampUintMin1(args[1], MAX_REWARD_ID)],
  "distribute-rewards-many": (args) => [
    args[0],
    clampUintMin1(args[1], MAX_REWARD_ID),
  ],
  "withdraw-dust": (args) => [clampUintMin1(args[0], MAX_REWARD_ID)],
};

exports.preClampArgs = (context) => {
  const rewrite = rewriters[context.selectedFunction.name];
  if (!rewrite) return;
  const next = rewrite(context.clarityValueArguments);
  for (let i = 0; i < next.length; i++) {
    context.clarityValueArguments[i] = next[i];
  }
};
