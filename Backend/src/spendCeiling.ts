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
 * complexity. A verified Pro transaction is never subject to this specific
 * ceiling (Pro traffic is expected to pay for its own cost) -- but it is
 * still subject to the absolute ceiling below, which has no such exception.
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

/**
 * A second, absolute ceiling on top of the one above: this one counts EVERY
 * request, a verified Pro transaction included. The Free-spend ceiling on
 * its own only bounds Free-tier cost -- it assumes Pro traffic always pays
 * for itself, which holds under normal use but is not a law of nature (a
 * verification bug, a future free-trial period that counts as "Pro" before
 * any charge lands, or one subscriber running far more decisions than their
 * plan assumes could all put real, unbudgeted cost on the Pro side with
 * nothing here to stop it). This is the backstop for that: whatever the
 * cause, total company-wide AI spend for the calendar month can never exceed
 * DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD, full stop -- including refusing
 * a verified Pro request in the pathological case where it trips. That is a
 * real cost (a paying customer briefly throttled) but a bounded and visible
 * one, chosen deliberately over an unbounded one.
 *
 * Set to $5 by explicit choice, not a rough guess: at pre-revenue,
 * zero-Pro-subscriber stage there is no real Pro cost to accommodate yet, so
 * the ceiling can sit at the actual maximum the business is willing to lose
 * in the worst month, full stop. This WILL throttle real Pro traffic the
 * moment usage costs more than $5/month combined across every subscriber --
 * that is expected and correct at this stage, not a bug. Raise it the
 * moment there are real paying subscribers to serve; a ceiling left here
 * after that point stops being a safety net and starts being an outage.
 */
export const DEFAULT_MONTHLY_ABSOLUTE_SPEND_CEILING_USD = 5;

export interface SpendCeilingDecision {
  allowed: boolean;
  spentUsd: number;
  ceilingUsd: number;
}

interface Bucket {
  spentUsd: number;
  monthKey: string;
}

const localBuckets = new Map<string, Bucket>();

function monthKey(now: number): string {
  const d = new Date(now);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

async function checkSpendCeiling(
  bucketName: string,
  estimatedCostUsd: number,
  ceilingUsd: number,
  now: number
): Promise<SpendCeilingDecision> {
  const key = `decide:${bucketName}:${monthKey(now)}`;
  if (isConfigured()) return checkRedis(key, estimatedCostUsd, ceilingUsd);
  return checkLocal(bucketName, monthKey(now), estimatedCostUsd, ceilingUsd);
}

/** Best-effort: gives back an estimate after a failed analysis, same
 * reasoning as quota.ts's refund -- losing a refund only tightens the
 * ceiling for the rest of the month, never loosens it. */
async function refundSpend(bucketName: string, estimatedCostUsd: number, now: number): Promise<void> {
  const key = `decide:${bucketName}:${monthKey(now)}`;
  if (isConfigured()) {
    try {
      await pipeline([["INCRBYFLOAT", key, String(-estimatedCostUsd)]]);
    } catch {
      // Acceptable to lose; never fabricate.
    }
    return;
  }
  const bucket = localBuckets.get(bucketName);
  if (bucket && bucket.monthKey === monthKey(now)) {
    bucket.spentUsd = Math.max(0, bucket.spentUsd - estimatedCostUsd);
  }
}

export async function checkGlobalFreeSpendCeiling(
  estimatedCostUsd: number,
  ceilingUsd: number = DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD,
  now: number = Date.now()
): Promise<SpendCeilingDecision> {
  return checkSpendCeiling("freespend", estimatedCostUsd, ceilingUsd, now);
}

export async function refundGlobalFreeSpend(estimatedCostUsd: number, now: number = Date.now()): Promise<void> {
  return refundSpend("freespend", estimatedCostUsd, now);
}

export async function checkAbsoluteSpendCeiling(
  estimatedCostUsd: number,
  ceilingUsd: number = DEFAULT_MONTHLY_ABSOLUTE_SPEND_CEILING_USD,
  now: number = Date.now()
): Promise<SpendCeilingDecision> {
  return checkSpendCeiling("totalspend", estimatedCostUsd, ceilingUsd, now);
}

export async function refundAbsoluteSpend(estimatedCostUsd: number, now: number = Date.now()): Promise<void> {
  return refundSpend("totalspend", estimatedCostUsd, now);
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

function checkLocal(bucketName: string, month: string, estimatedCostUsd: number, ceilingUsd: number): SpendCeilingDecision {
  let bucket = localBuckets.get(bucketName);
  if (!bucket || bucket.monthKey !== month) {
    bucket = { spentUsd: 0, monthKey: month };
    localBuckets.set(bucketName, bucket);
  }
  bucket.spentUsd += estimatedCostUsd;
  return { allowed: bucket.spentUsd <= ceilingUsd, spentUsd: bucket.spentUsd, ceilingUsd };
}

export function resetGlobalFreeSpend(): void {
  localBuckets.delete("freespend");
}

export function resetAbsoluteSpend(): void {
  localBuckets.delete("totalspend");
}
