import type { AnalysisRequest } from "./schema.js";

/**
 * What one decision is allowed to spend.
 *
 * PREMIUM_MODEL (Gemini's stronger model) is unused by design, not
 * forgotten: confirmed live, three times in a row, that a single analysis
 * call on it -- at the lowest thinking level, with zero research -- still
 * failed to complete within Vercel's 60s function-duration ceiling (two
 * 504s, one upstream 503 after the model itself took 35-47s).
 *
 * The real differentiator for a "complex" decision is now GROQ_MODEL
 * instead: Groq runs it on dedicated inference hardware fast enough (~500
 * tokens/sec) to plausibly fit the same 60s ceiling that defeated
 * PREMIUM_MODEL, and it's free of charge, same as Gemini's tier here.
 * Research stays on Gemini for every complexity regardless -- its
 * google_search tool returns the clean, structured URL citations the
 * allow-list in validate.ts depends on; Groq's web-search tool returns
 * inline citation markers with no documented way to map them back to real
 * URLs, which isn't a safe foundation for "never cite a URL that wasn't
 * actually retrieved".
 *
 * Both Gemini models are on its free tier (see Backend/README.md) -- no
 * per-token credit balance that can silently run out, only rate limits that
 * fail loud and recover on their own.
 */
export const PREMIUM_MODEL = "gemini-3.8-flash";
export const STANDARD_MODEL = "gemini-3.5-flash-lite";
export const GROQ_MODEL = "openai/gpt-oss-120b";

export type Effort = "low" | "medium" | "high";
export type Provider = "gemini" | "groq";

export interface Budget {
  /** Which provider analyse() should call for the main analysis step. */
  provider: Provider;
  /** The model for the analysis call, on `provider`. */
  model: string;
  /** The model for the research call -- always a Gemini model; see above. */
  researchModel: string;
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

  const provider: Provider = request.complexity === "complex" ? "groq" : "gemini";
  const model = provider === "groq" ? GROQ_MODEL : STANDARD_MODEL;

  return { provider, model, researchModel: STANDARD_MODEL, effort, maxTokens, maxSearches, questionsRemaining };
}
