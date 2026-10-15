import { isConfigured, pipeline } from "./redis.js";

/**
 * A hard ceiling on simultaneous, in-flight analyse() calls, independent of
 * client identity.
 *
 * The rate limiter counts requests over time, per client key. It says nothing
 * about how many of those calls are running *at once* — and a client key is
 * only as trustworthy as the identity behind it (an IP, freely rotated; a
 * bearer token, extractable from the app). This is the backstop that holds
 * even if every client key is spoofed: however many identities arrive at
 * once, only a bounded number can be spending money against the model
 * provider at the same time.
 *
 * Backed by Redis when configured (see redis.ts) — an in-process counter
 * cannot hold across requests that land on different serverless instances,
 * which is the normal case on Vercel, not an edge case. Falls back to an
 * in-process counter for local development and tests.
 */
let active = 0;

const CONCURRENCY_KEY = "decide:concurrency";
/** Self-heals a slot leaked by an instance that crashed before releasing --
 * comfortably above the server's actual worst case, not a real budget.
 *
 * Must stay well above Vercel's own `maxDuration` (60s, see vercel.json): a
 * request killed by that hard ceiling never reaches the `finally { release() }`
 * in handler.ts, so its slot can only clear via this expiry. The key's TTL is
 * set once, at first creation (`EXPIRE ... NX` below never refreshes it on
 * later INCRs), so the true bound on how long any single leak can survive is
 * (this value) seconds after the LEAKING request's own INCR created or found
 * the key -- not after that request finishes. A value equal to or only
 * slightly above maxDuration (as a stale 60/60 once sat here) leaves zero
 * margin and was confirmed live: a build still well under its own 52s
 * internal deadline (PIPELINE_DEADLINE_MS, analyze.ts) hit "Too many
 * decisions at once" from a single real client with nothing else running
 * against it, immediately and on every retry for the better part of a
 * minute -- consistent with an earlier leaked slot whose 60s clock hadn't
 * run out yet. */
const STALE_SECONDS = 90;

export async function tryAcquire(limit: number): Promise<boolean> {
  if (!isConfigured()) {
    if (active >= limit) return false;
    active += 1;
    return true;
  }
  try {
    const [count] = await pipeline([
      ["INCR", CONCURRENCY_KEY],
      ["EXPIRE", CONCURRENCY_KEY, STALE_SECONDS, "NX"],
    ]);
    if (Number(count) > limit) {
      await pipeline([["DECR", CONCURRENCY_KEY]]);
      return false;
    }
    return true;
  } catch {
    // Fails closed: an unreachable counter must not become unlimited concurrency.
    return false;
  }
}

export async function release(): Promise<void> {
  if (!isConfigured()) {
    active = Math.max(0, active - 1);
    return;
  }
  try {
    await pipeline([["DECR", CONCURRENCY_KEY]]);
  } catch {
    // Best-effort: a failed release only leaks a slot for STALE_SECONDS.
  }
}

export async function currentlyActive(): Promise<number> {
  if (!isConfigured()) return active;
  try {
    const [count] = await pipeline([["GET", CONCURRENCY_KEY]]);
    return Number(count ?? 0);
  } catch {
    return 0;
  }
}

export function resetConcurrency(): void {
  active = 0;
}
