import type { AnalysisRequest } from "./schema.js";

/**
 * What one decision is allowed to spend.
 *
 * PREMIUM_MODEL is currently unused by design, not forgotten: confirmed live,
 * three times in a row, that a single analysis call on it -- at the lowest
 * thinking level, with zero research -- still failed to complete within
 * Vercel's 60s function-duration ceiling (two 504s, one upstream 503 after
 * the model itself took 35-47s). Every complexity runs on STANDARD_MODEL for
 * now. The Free/Pro boundary is still enforced exactly as before -- a
 * complex ("deep") decision is still the one that needs Pro or the trial --
 * it just isn't backed by a stronger model at the moment. Bring PREMIUM_MODEL
 * back for "complex" once Vercel's ceiling is raised (a paid plan lifts it to
 * 300s) or the model proves reliably faster; see AppStore/RELEASE.md. Both
 * models are on Gemini's free tier (see Backend/README.md) -- no per-token
 * credit balance that can silently run out, only rate limits that fail loud
 * and recover on their own.
 */
export const PREMIUM_MODEL = "gemini-3.8-flash";
export const STANDARD_MODEL = "gemini-3.5-flash-lite";

export type Effort = "low" | "medium" | "high";

export interface Budget {
  model: string;
  effort: Effort;
  maxTokens: number;
  /** Server-side web searches allowed for this decision. 0 means no research call at all. */
  maxSearches: number;
  /** Questions the model may return, after what has already been asked. */
  questionsRemaining: number;
}

export function budgetFor(request: AnalysisRequest): Budget {
  const effort: Effort = request.complexity === "simple" ? "low" : "medium";

  // On Gemini, max_output_tokens is a hard cap that includes thinking tokens,
  // not just the visible answer -- a budget sized for the previous provider's
  // separate thinking/output accounting left too little room for the actual
  // JSON once thinking ate into it (confirmed live: a "simple" decision came
  // back with unparseable/truncated output at 8000). Doubled with margin.
  const maxTokens = 16000;

  // Research is capped by the app's budget and by complexity, whichever is lower.
  const byLevel = request.researchLevel === "deep" ? 2 : request.researchLevel === "light" ? 2 : 0;
  const maxSearches = Math.max(0, Math.min(byLevel, request.maximumResearchCalls));

  const questionsRemaining = Math.max(
    0,
    Math.min(request.questionCeiling - request.questionsAlreadyAsked, 5)
  );

  const model = STANDARD_MODEL;

  return { model, effort, maxTokens, maxSearches, questionsRemaining };
}
