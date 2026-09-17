import { isConfigured, pipeline } from "./redis.js";

/**
 * A hard, absolute ceiling on how much AI spend the Free tier can cost in one
 * calendar month, independent of every growth/conversion assumption.
 *
 * The per-install quota (quota.ts) stops any *one* install from costing too
 * much. It does not, by itself, bound the total: enough simultaneous installs
 * each spending their own small quota can still add up past what the
 * business can absorb before conversion catches up. This is the backstop --
 * once total estimated Free-tier spend for the month crosses
 * DECIDE_MONTHLY_FREE_SPEND_CEILING_USD, every further Free-tier request is
 * refused (fail closed) until the next calendar month, whatever its
 * complexity. A verified Pro transaction is never subject to this ceiling:
 * Pro traffic pays for its own cost, so there is nothing here to bound.
 *
 * The per-complexity costs below are rough estimates, not a bill -- tune
 * them against actual Anthropic usage once real traffic exists (see
 * Backend/README.md's "Cost" section for the token/search budget each
 * complexity spends).
 */
export const ESTIMATED_COST_USD: Record<"simple" | "medium" | "complex", number> = {
  simple: 0.02,
  medium: 0.06,
  complex: 0.3,
};

// Set to $12, not $30: at bootstrap-stage volume, this ceiling plus fixed
// hosting cost is the real monthly floor cost the payer base has to outrun,
// and a lower ceiling shrinks that floor directly -- see the "Bootstrap"
// scenario in the Rudder Vision Model for the concrete effect (worst
// cumulative drawdown drops from roughly -$400 to roughly -$20 across the
// same 24 months, holding every growth/conversion assumption fixed). Raise
// it once real conversion data justifies carrying more Free-tier cost.
export const DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD = 12;

export interface SpendCeilingDecision {
  allowed: boolean;
  spentUsd: number;
  ceilingUsd: number;
}

interface Bucket {
  spentUsd: number;
  monthKey: string;
}

const localBucket = new Map<string, Bucket>();
const GLOBAL_KEY = "global";

function monthKey(now: number): string {
  const d = new Date(now);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

export async function checkGlobalFreeSpendCeiling(
  estimatedCostUsd: number,
  ceilingUsd: number = DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD,
  now: number = Date.now()
): Promise<SpendCeilingDecision> {
  const key = `decide:freespend:${monthKey(now)}`;
  if (isConfigured()) return checkRedis(key, estimatedCostUsd, ceilingUsd);
  return checkLocal(monthKey(now), estimatedCostUsd, ceilingUsd);
}

/** Best-effort: gives back an estimate after a failed analysis, same
 * reasoning as quota.ts's refund -- losing a refund only tightens the
 * ceiling for the rest of the month, never loosens it. */
export async function refundGlobalFreeSpend(estimatedCostUsd: number, now: number = Date.now()): Promise<void> {
  const key = `decide:freespend:${monthKey(now)}`;
  if (isConfigured()) {
    try {
      await pipeline([["INCRBYFLOAT", key, String(-estimatedCostUsd)]]);
    } catch {
      // Acceptable to lose; never fabricate.
    }
    return;
  }
  const bucket = localBucket.get(GLOBAL_KEY);
  if (bucket && bucket.monthKey === monthKey(now)) {
    bucket.spentUsd = Math.max(0, bucket.spentUsd - estimatedCostUsd);
  }
}

async function checkRedis(key: string, estimatedCostUsd: number, ceilingUsd: number): Promise<SpendCeilingDecision> {
  try {
    const [spent] = await pipeline([
      ["INCRBYFLOAT", key, String(estimatedCostUsd)],
      ["EXPIRE", key, 40 * 24 * 60 * 60, "NX"],
    ]);
    const spentUsd = Number(spent);
    return { allowed: spentUsd <= ceilingUsd, spentUsd, ceilingUsd };
  } catch {
    // Fails closed, same reasoning as every other limiter here: unreachable
    // must never mean unlimited.
    return { allowed: false, spentUsd: ceilingUsd + estimatedCostUsd, ceilingUsd };
  }
}

function checkLocal(month: string, estimatedCostUsd: number, ceilingUsd: number): SpendCeilingDecision {
  let bucket = localBucket.get(GLOBAL_KEY);
  if (!bucket || bucket.monthKey !== month) {
    bucket = { spentUsd: 0, monthKey: month };
    localBucket.set(GLOBAL_KEY, bucket);
  }
  bucket.spentUsd += estimatedCostUsd;
  return { allowed: bucket.spentUsd <= ceilingUsd, spentUsd: bucket.spentUsd, ceilingUsd };
}

export function resetGlobalFreeSpend(): void {
  localBucket.clear();
}
