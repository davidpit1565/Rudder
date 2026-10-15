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
 * Set to 0, not a small positive number: a *recurring* monthly allowance
 * (even a small one) is something a casual user can permanently settle into
 * without ever converting -- there is no pressure to try Pro if "what I
 * already have" never runs out in a way that matters to them. The first
 * decision ever is still always free (see `AppEnvironment.canStartDecision`
 * / `FeatureAccess.allowsDeepDecision`'s own `completedDecisionCount == 0`
 * check) -- that is the product's one unconditional "try it" moment. Beyond
 * that, the real try-before-you-buy mechanism is the App Store's own
 * introductory free trial on the Pro subscription (see
 * AppStore/subscriptions.md), not a recurring free allowance: a trial has a
 * natural end and converts into a real subscription unless cancelled, so it
 * doesn't have this same "good enough forever" failure mode.
 */
export const DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH = 0;

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

/** Reads the monthly complex-decision quota's current usage without spending
 * a unit -- for showing "first decision used" / "N of M this month" in the
 * app without that look itself counting as a decision. */
export async function peekDeepDecisionQuota(
  installId: string,
  limit: number = DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH,
  now: number = Date.now()
): Promise<QuotaDecision> {
  const { monthKey, secondsRemaining } = monthKeyAndSecondsRemaining(now);
  const effectiveLimit = Math.max(limit, 1);
  if (isConfigured()) {
    try {
      const [count] = await pipeline([["GET", `decide:deepquota:${monthKey}:${installId}`]]);
      const used = Number(count ?? 0);
      return { allowed: used < effectiveLimit, used, limit, retryAfterSeconds: secondsRemaining };
    } catch {
      // Same reasoning as peekDailyQuota: a display-only read that fails
      // reports the safe (zero-usage) answer rather than failing closed.
      return { allowed: true, used: 0, limit, retryAfterSeconds: secondsRemaining };
    }
  }
  const existing = localCounters.get(installId);
  const used = existing && existing.monthKey === monthKey ? existing.count : 0;
  return { allowed: used < effectiveLimit, used, limit, retryAfterSeconds: secondsRemaining };
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
    // max(limit, 1): the very first spend is always allowed even when limit is
    // 0, mirroring the app's own unconditional "first decision ever is free"
    // rule (FeatureAccess.allowsDeepDecision's completedDecisionCount == 0
    // check) -- without this, a limit of 0 would reject that first decision
    // server-side even though the app just told the user it was free.
    return { allowed: used <= Math.max(limit, 1), used, limit, retryAfterSeconds: secondsRemaining };
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
    return { allowed: 1 <= Math.max(limit, 1), used: 1, limit, retryAfterSeconds: secondsRemaining };
  }
  existing.count += 1;
  return {
    allowed: existing.count <= Math.max(limit, 1),
    used: existing.count,
    limit,
    retryAfterSeconds: secondsRemaining,
  };
}

export function resetDeepDecisionQuota(): void {
  localCounters.clear();
}

/**
 * Daily quota buckets -- separate from the monthly complex-only quota above.
 * "simple" is always unlimited. "medium" is capped per day for both Free and
 * Pro (a higher cap for Pro). "complex" additionally gets a daily cap even
 * for a verified Pro subscriber: unlike the monthly quota above (which
 * exists specifically to make a *Free*-tier complex decision rare), this one
 * is a pure abuse backstop for Pro, set generous enough that no real user
 * doing real decision-making hits it.
 *
 * `bucket` names which cap this is ("medium-free", "medium-pro",
 * "complex-pro") so the same install is tracked independently per bucket --
 * switching between Free and Pro mid-day, or between complexities, never
 * shares or resets another bucket's count.
 *
 * Resets at UTC midnight, not local time: this matches the existing monthly
 * quota's own UTC month boundary above, and avoids the alternative (a
 * rolling 24h-from-first-use window per install) needing its own per-user
 * anchor timestamp -- more storage, and a reset time that looks arbitrary to
 * the one user who hits it. UTC's own midnight sits within an hour of
 * London's (GMT, or BST in summer), which is the one piece of real-world
 * framing this needs.
 */
export const DEFAULT_FREE_MEDIUM_DAILY_LIMIT = 5;
export const DEFAULT_PRO_MEDIUM_DAILY_LIMIT = 15;
export const DEFAULT_PRO_COMPLEX_DAILY_LIMIT = 5;

/**
 * A follow-up question on an already-finished decision is its own bucket,
 * separate from the decision-creation buckets above -- a user re-reading
 * their recommendation and asking "what about X" should not eat into the
 * same allowance as starting a brand new decision. Kept conservative (10 for
 * Pro, not 15 like medium) as a deliberate starting point: easy to raise
 * later if real usage calls for it, hard to walk back down without
 * frustrating users already used to a higher number.
 */
export const DEFAULT_FREE_FOLLOWUP_DAILY_LIMIT = 3;
export const DEFAULT_PRO_FOLLOWUP_DAILY_LIMIT = 10;

interface DailyCounter {
  count: number;
  dayKey: string;
}

const dailyLocalCounters = new Map<string, DailyCounter>();

function dayKeyAndSecondsRemaining(now: number): { dayKey: string; secondsRemaining: number; resetsAt: string } {
  const d = new Date(now);
  const dayKey = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
  const nextDay = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
  return { dayKey, secondsRemaining: Math.ceil((nextDay - now) / 1000), resetsAt: new Date(nextDay).toISOString() };
}

export interface DailyQuotaDecision extends QuotaDecision {
  /** ISO 8601 instant this bucket next resets -- the next UTC midnight. */
  resetsAt: string;
}

/** Spends one unit of `bucket`'s daily quota and reports whether it fit.
 * Called before the (expensive) analysis runs -- pair with
 * `refundDailyQuota` if the analysis then fails, so a transient error
 * doesn't cost the user a real attempt. Unlike the monthly complex quota
 * above, there is no "first spend is always free" exception here -- every
 * bucket's limit is already a real, positive daily allowance. */
export async function checkDailyQuota(
  bucket: string,
  installId: string,
  limit: number,
  now: number = Date.now()
): Promise<DailyQuotaDecision> {
  const { dayKey, secondsRemaining, resetsAt } = dayKeyAndSecondsRemaining(now);
  const decision = isConfigured()
    ? await checkDailyRedis(bucket, installId, dayKey, limit, secondsRemaining)
    : checkDailyLocal(bucket, installId, dayKey, limit, secondsRemaining);
  return { ...decision, resetsAt };
}

/** Reads `bucket`'s current usage without spending a unit -- for showing
 * "X of Y used today" in the app without that look itself counting as a
 * decision. */
export async function peekDailyQuota(
  bucket: string,
  installId: string,
  limit: number,
  now: number = Date.now()
): Promise<DailyQuotaDecision> {
  const { dayKey, secondsRemaining, resetsAt } = dayKeyAndSecondsRemaining(now);
  if (isConfigured()) {
    try {
      const [count] = await pipeline([["GET", `decide:dailyquota:${bucket}:${dayKey}:${installId}`]]);
      const used = Number(count ?? 0);
      return { allowed: used < limit, used, limit, retryAfterSeconds: secondsRemaining, resetsAt };
    } catch {
      // A peek that can't be read reports the safe (zero-usage) answer --
      // unlike checkDailyRedis, nothing is actually being spent here, so
      // failing open on a display-only read doesn't risk real over-spend.
      return { allowed: true, used: 0, limit, retryAfterSeconds: secondsRemaining, resetsAt };
    }
  }
  const existing = dailyLocalCounters.get(`${bucket}:${installId}`);
  const used = existing && existing.dayKey === dayKey ? existing.count : 0;
  return { allowed: used < limit, used, limit, retryAfterSeconds: secondsRemaining, resetsAt };
}

/** Best-effort: gives back one unit of `bucket`'s daily quota after a failed
 * analysis. A lost refund (e.g. a transient Redis error) only makes the
 * quota one attempt stricter for that install today -- never looser, which
 * is the direction that would actually cost money. */
export async function refundDailyQuota(bucket: string, installId: string, now: number = Date.now()): Promise<void> {
  const { dayKey } = dayKeyAndSecondsRemaining(now);
  if (isConfigured()) {
    try {
      await pipeline([["DECR", `decide:dailyquota:${bucket}:${dayKey}:${installId}`]]);
    } catch {
      // See doc comment: acceptable to lose a refund, never to fabricate one.
    }
    return;
  }
  const key = `${bucket}:${installId}`;
  const existing = dailyLocalCounters.get(key);
  if (existing && existing.dayKey === dayKey && existing.count > 0) existing.count -= 1;
}

async function checkDailyRedis(
  bucket: string,
  installId: string,
  dayKey: string,
  limit: number,
  secondsRemaining: number
): Promise<QuotaDecision> {
  const key = `decide:dailyquota:${bucket}:${dayKey}:${installId}`;
  try {
    // A 2-day TTL rather than exactly "until midnight": it only needs to
    // outlive the day, and NX means it's set once, on the first spend.
    const [count] = await pipeline([
      ["INCR", key],
      ["EXPIRE", key, 2 * 24 * 60 * 60, "NX"],
    ]);
    const used = Number(count);
    return { allowed: used <= limit, used, limit, retryAfterSeconds: secondsRemaining };
  } catch {
    // Fails closed, same reasoning as rateLimit.ts: a quota that can't be
    // reached must not become an unlimited one.
    return { allowed: false, used: limit + 1, limit, retryAfterSeconds: secondsRemaining };
  }
}

function checkDailyLocal(
  bucket: string,
  installId: string,
  dayKey: string,
  limit: number,
  secondsRemaining: number
): QuotaDecision {
  const key = `${bucket}:${installId}`;
  const existing = dailyLocalCounters.get(key);
  if (!existing || existing.dayKey !== dayKey) {
    dailyLocalCounters.set(key, { count: 1, dayKey });
    return { allowed: 1 <= limit, used: 1, limit, retryAfterSeconds: secondsRemaining };
  }
  existing.count += 1;
  return { allowed: existing.count <= limit, used: existing.count, limit, retryAfterSeconds: secondsRemaining };
}

export function resetDailyQuota(): void {
  dailyLocalCounters.clear();
}
