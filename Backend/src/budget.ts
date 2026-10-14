import type { AnalysisRequest } from "./schema.js";

/**
 * What one decision is allowed to spend.
 *
 * Every complexity's analysis step runs on GROQ_MODEL now, not just
 * "complex" -- confirmed live, repeatedly, that Gemini's free tier is
 * currently both too slow (a single call, zero retries, taking 25-50+
 * seconds) and outright unreliable (three "simple" decisions in a row came
 * back with a response that failed JSON parsing, despite responding well
 * inside the time budget). Groq's dedicated inference hardware doesn't share
 * either failure mode. This does trade away having two independent analysis
 * providers -- if Groq itself has a bad day, every complexity is affected,
 * not just one -- but an unreliable Gemini failing most "simple"/"medium"
 * decisions today is a worse starting point than a single fast, reliable
 * provider. Revisit if Groq's free tier shows the same cracks under real
 * traffic; PREMIUM_MODEL and STANDARD_MODEL stay defined for exactly that.
 *
 * PREMIUM_MODEL (Gemini's stronger model) is unused by design, not
 * forgotten: confirmed live, three times in a row, that a single analysis
 * call on it -- at the lowest thinking level, with zero research -- still
 * failed to complete within Vercel's 60s function-duration ceiling (two
 * 504s, one upstream 503 after the model itself took 35-47s).
 *
 * STANDARD_MODEL is still used for every research call, on every complexity
 * -- Gemini's google_search tool returns the clean, structured URL citations
 * the allow-list in validate.ts depends on; Groq's web-search tool returns
 * inline citation markers with no documented way to map them back to real
 * URLs, which isn't a safe foundation for "never cite a URL that wasn't
 * actually retrieved". Research depth is controlled by `researchLevel`, not
 * by complexity or by which provider does the analysis -- moving analysis to
 * Groq does not trade away research depth for any complexity.
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
  // "complex" was briefly given "high" here to actually differ from "medium"
  // in more than just token/research ceilings -- reverted after confirming
  // live, repeatedly, that "high" effort combined with ANY research (light
  // or deep, not just deep) reliably overran the whole pipeline deadline: two
  // timeouts and one real Groq-side error in three attempts, versus a fast,
  // clean 17.5s with no research. Rebalancing the research/analysis time
  // split (see PIPELINE_DEADLINE_MS/RESEARCH_TIMEOUT_MS) didn't fix it --
  // "high" effort with a research-augmented prompt is just too slow for
  // Groq to reliably finish inside Vercel's 60s ceiling, which is the common
  // case for a "complex" decision. Revisit once there's a way to raise the
  // ceiling itself or confirm a faster way to get "high"-quality output.
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

  // See the comment on GROQ_MODEL above: every complexity's analysis now runs
  // on Groq. `provider` stays a real field, not a hardcoded call site, so a
  // single complexity (or all of them) can move back to Gemini with a
  // one-line change here if Groq's own free tier turns out to need it.
  const provider: Provider = "groq";
  const model = GROQ_MODEL;

  return { provider, model, researchModel: STANDARD_MODEL, effort, maxTokens, maxSearches, questionsRemaining };
}
