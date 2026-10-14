import type { AnalysisRequest } from "./schema.js";

/**
 * What one decision is allowed to spend.
 *
 * Model choice is the primary lever, split exactly on the Free/Pro boundary
 * the app already enforces: a complex ("deep") decision is the one that needs
 * Pro or the trial, so it's the only one that runs on the stronger model.
 * Simple and medium decisions are free and unlimited for everyone, and run on
 * the lighter model. Both models are on Gemini's free tier (see
 * Backend/README.md) -- no per-token credit balance that can silently run
 * out, only rate limits that fail loud and recover on their own. Effort
 * (thinking_level, output tokens, searches) is still the secondary lever
 * within whichever model a request gets.
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
  // A complex decision runs two sequential model calls (research, then
  // analysis) on the stronger model, and still has to clear Vercel's 60s
  // function-duration ceiling. Confirmed live: the stronger model alone, at
  // "medium" thinking and zero research, already took 52s for one call --
  // adding a research call on top blew past 60s outright. Kept at "low" (the
  // same as "simple") so the premium model remains the one real
  // differentiator for a complex decision, not deeper thinking it can't
  // afford the time for. Re-measure before raising this; see AppStore/RELEASE.md.
  const effort: Effort = request.complexity === "medium" ? "medium" : "low";

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

  const model = request.complexity === "complex" ? PREMIUM_MODEL : STANDARD_MODEL;

  return { model, effort, maxTokens, maxSearches, questionsRemaining };
}
