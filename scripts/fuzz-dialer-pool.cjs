// Rendezvous pre-dialer for pox4-self-service-multi-v2.
//
// Clamps STX amounts to wallet-sized values so delegate-stx can actually
// transfer, and drops the rarely-used `until-burn-ht` option so delegations
// don't auto-expire before extend/increase.
//
// Only clarityValueArguments is mutable; callers and burn-block advances are
// Rendezvous-controlled.

const { Cl } = require("@stacks/transactions");

// Devnet wallets hold 100_000 STX = 100_000_000_000 µSTX. Use at most 20k STX
// so repeated delegate-stx calls don't drain the caller's balance.
const MAX_AMOUNT_USTX = 20_000_000_000n;
const MIN_AMOUNT_USTX = 1_000_000_000n; // 1000 STX, above pox-4 minimum

const toBig = (cv) => BigInt(cv.value);

const clampAmount = (cv) =>
  Cl.uint((toBig(cv) % (MAX_AMOUNT_USTX - MIN_AMOUNT_USTX)) + MIN_AMOUNT_USTX);

const rewriters = {
  "delegate-stx": (args) => [clampAmount(args[0]), args[1]],
  "set-stx-buffer": (args) => [
    // Keep buffer small so it never eats the entire delegated amount.
    Cl.uint((toBig(args[0]) % 5_000_000n) + 1n),
  ],
};

exports.preClampArgs = (context) => {
  const rewrite = rewriters[context.selectedFunction.name];
  if (!rewrite) return;
  const next = rewrite(context.clarityValueArguments);
  for (let i = 0; i < next.length; i++) {
    context.clarityValueArguments[i] = next[i];
  }
};
