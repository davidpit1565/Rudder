import { isConfigured, pipeline } from "./redis.js";

/**
 * How many "complex" (deep) decisions one install may spend without proof of
 * a Pro subscription, per calendar month -- the server-side mirror of the
 * app's own `FeatureAccess.freeDeepDecisionsPerMonth` (App/App/
 * AppEnvironment.swift). The two are not wired together (Swift and
 * TypeScript can't share a constant), so keep them in sync by hand if either
 * changes.
 *
 * Before this existed, this ceiling was enforced only on the device: the
 * backend accepted whatever `complexity`/`researchLevel` a request declared,
 * for anyone who could reach the endpoint at all. This is the fix -- an
 * independent, server-side ceiling that holds regardless of what the client
 * claims, closing the gap the OWASP-style monetization audit found
 * (Backend/README.md's "Known gap" section covers the sibling gap, client
 * identity itself).
 *
 * Set to 1, not 3: at low volume the free tier's own cost is the dominant
 * risk (see spendCeiling.ts), and a stingier free deep-decision allowance is
 * a direct, immediate lever on it -- it does not touch simple or medium
 * decisions (still unlimited on Free), and it never touches the very first
 * decision a new install ever makes, which `FeatureAccess.allowsDeepDecision`
 * always allows regardless of this number. Raise it again once real
 * conversion data justifies the extra cost.
 */
export const DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH = 1;

export interface QuotaDecision {
  allowed: boolean;
  used: number;
  limit: number;
  /** Seconds until the quota resets, for a Retry-After header. */
  retryAfterSeconds: number;
}

interface Counter {
  count: number;
  monthKey: string;
}

const localCounters = new Map<string, Counter>();

function monthKeyAndSecondsRemaining(now: number): { monthKey: string; secondsRemaining: number } {
  const d = new Date(now);
  const monthKey = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
  const nextMonth = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1);
  return { monthKey, secondsRemaining: Math.ceil((nextMonth - now) / 1000) };
}

/** Spends one unit of the monthly quota and reports whether it fit. Called
 * before the (expensive) analysis runs -- pair with `refundDeepDecisionQuota`
 * if the analysis then fails, so a transient error doesn't cost the user a
 * real attempt. */
export async function checkDeepDecisionQuota(
  installId: string,
  limit: number = DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH,
  now: number = Date.now()
): Promise<QuotaDecision> {
  const { monthKey, secondsRemaining } = monthKeyAndSecondsRemaining(now);
  if (isConfigured()) return checkRedis(installId, monthKey, limit, secondsRemaining);
  return checkLocal(installId, monthKey, limit, secondsRemaining);
}

/** Best-effort: gives back one unit after a failed analysis. A lost refund
 * (e.g. a transient Redis error) only makes the quota one attempt stricter
 * for that install this month -- never looser, which is the direction that
 * would actually cost money. */
export async function refundDeepDecisionQuota(installId: string, now: number = Date.now()): Promise<void> {
  const { monthKey } = monthKeyAndSecondsRemaining(now);
  if (isConfigured()) {
    try {
      await pipeline([["DECR", `decide:deepquota:${monthKey}:${installId}`]]);
    } catch {
      // See doc comment: acceptable to lose a refund, never to fabricate one.
    }
    return;
  }
  const existing = localCounters.get(installId);
  if (existing && existing.monthKey === monthKey && existing.count > 0) existing.count -= 1;
}

async function checkRedis(
  installId: string,
  monthKey: string,
  limit: number,
  secondsRemaining: number
): Promise<QuotaDecision> {
  const key = `decide:deepquota:${monthKey}:${installId}`;
  try {
    // A 40-day TTL rather than exactly "until month end": it only needs to
    // outlive the month, and NX means it's set once, on the first spend.
    const [count] = await pipeline([
      ["INCR", key],
      ["EXPIRE", key, 40 * 24 * 60 * 60, "NX"],
    ]);
    const used = Number(count);
    return { allowed: used <= limit, used, limit, retryAfterSeconds: secondsRemaining };
  } catch {
    // Fails closed, same reasoning as rateLimit.ts: a quota that can't be
    // reached must not become an unlimited one.
    return { allowed: false, used: limit + 1, limit, retryAfterSeconds: secondsRemaining };
  }
}

function checkLocal(installId: string, monthKey: string, limit: number, secondsRemaining: number): QuotaDecision {
  const existing = localCounters.get(installId);
  if (!existing || existing.monthKey !== monthKey) {
    localCounters.set(installId, { count: 1, monthKey });
    return { allowed: 1 <= limit, used: 1, limit, retryAfterSeconds: secondsRemaining };
  }
  existing.count += 1;
  return { allowed: existing.count <= limit, used: existing.count, limit, retryAfterSeconds: secondsRemaining };
}

export function resetDeepDecisionQuota(): void {
  localCounters.clear();
}
