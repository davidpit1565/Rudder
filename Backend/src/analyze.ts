import type { GoogleGenAI } from "@google/genai";
import type OpenAI from "openai";
import { APIConnectionTimeoutError } from "openai";
import { DecisionResponseSchema, type AnalysisRequest, type WireResponse } from "./schema.js";
import { budgetFor, type Budget } from "./budget.js";
import { SYSTEM_PROMPT, OUTPUT_FORMAT_INSTRUCTIONS, buildUserMessage } from "./prompt.js";
import { renderResearchNotes, runResearch } from "./research.js";
import { toWireResponse } from "./validate.js";

export class AnalysisError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "AnalysisError";
  }
}

export interface AnalysisClients {
  gemini: GoogleGenAI;
  groq: OpenAI;
}

/**
 * Wall-clock budget for the whole pipeline (research + analysis), well under
 * Vercel's 60s hard function-duration ceiling. Confirmed live: even with the
 * SDK's own retry-on-rate-limit disabled (see getClients() in handler.ts),
 * a single Gemini call can itself take 25-50+ seconds under real load, with
 * no error of any kind until Vercel kills the function cold -- a bare
 * FUNCTION_INVOCATION_TIMEOUT, no JSON body, indistinguishable to the app
 * from a crash. That is a different failure than the retry storm: it can
 * happen on the first and only attempt. Bounding each call explicitly turns
 * it into a normal, fast, JSON `upstream_unavailable` instead.
 *
 * Raised from 50s to 52s, alongside trimming RESEARCH_TIMEOUT_MS in
 * research.ts: confirmed live that "complex" (now "high" effort, see
 * budget.ts) with deep research consistently needed more of this budget than
 * 50s/20s left for the analysis call, and was cut off by this deadline on
 * every attempt. Still 8s of real margin under Vercel's ceiling.
 */
const PIPELINE_DEADLINE_MS = 52_000;

/**
 * The whole pipeline for one decision: research what can be researched, then
 * analyse, then validate before anything is returned.
 */
export async function analyse(clients: AnalysisClients, request: AnalysisRequest): Promise<WireResponse> {
  const budget = budgetFor(request);
  const pipelineStart = Date.now();

  let researchNotes: string | null = null;
  let retrievedUrls = new Map<string, string>();

  try {
    // Research always runs on Gemini, whichever provider does the analysis --
    // see the comment on PREMIUM_MODEL/GROQ_MODEL in budget.ts for why.
    const research = await runResearch(clients.gemini, request, budget);
    if (research) {
      researchNotes = renderResearchNotes(research);
      retrievedUrls = research.retrievedUrls;
    }
  } catch {
    // Research is best-effort: the analysis proceeds and says what it could not
    // verify, rather than failing the whole decision. This also covers research
    // timing out (see PIPELINE_DEADLINE_MS) -- same handling either way.
    researchNotes = null;
  }

  // Whatever research did or didn't use, the analysis call gets what's left
  // of the shared deadline, never the full budget again -- otherwise two
  // sequential Gemini calls (research, then analysis) could each individually
  // stay under their own cap while still blowing the 60s ceiling together.
  const analysisTimeoutMs = Math.max(10_000, PIPELINE_DEADLINE_MS - (Date.now() - pipelineStart));

  const text =
    budget.provider === "groq"
      ? await analyseWithGroq(clients.groq, request, budget, researchNotes, analysisTimeoutMs)
      : await analyseWithGemini(clients.gemini, request, budget, researchNotes, analysisTimeoutMs);

  let rawOutput: unknown;
  try {
    rawOutput = JSON.parse(extractJsonObject(text));
  } catch {
    // Diagnostic only -- length, never the decision content itself.
    console.error(`${budget.provider} response was not valid JSON`, { textLength: text.length });
    throw new AnalysisError("unparseable_response", 502);
  }

  // Re-validated here rather than trusted: nothing about the prompted-JSON
  // approach above guarantees the shape, so this is not redundant -- it is
  // the only real enforcement of the contract before anything reaches the app.
  const parsed = DecisionResponseSchema.safeParse(rawOutput);
  if (!parsed.success) {
    console.error(`${budget.provider} response was valid JSON but failed the contract`, {
      issues: parsed.error.issues.slice(0, 5).map((issue) => ({ path: issue.path.join("."), message: issue.message })),
    });
    throw new AnalysisError("unparseable_response", 502);
  }

  return toWireResponse(parsed.data, request, budget, retrievedUrls);
}

/** Server-side only, never sent to the client: just enough to diagnose an
 * upstream failure (name, HTTP status, the provider's own message) without
 * logging the request, the response, or anything from process.env.
 * Duck-typed on `.status` rather than an imported error class, since that's
 * the one property both SDKs' errors are documented to carry consistently. */
function throwForUpstreamError(provider: string, error: unknown): never {
  const status = typeof (error as { status?: unknown })?.status === "number"
    ? (error as { status: number }).status
    : undefined;
  // A client-side request timeout (see PIPELINE_DEADLINE_MS) carries no HTTP
  // status -- there was no response -- so it isn't caught by the status check
  // below. Each SDK names its timeout error differently: Gemini sets
  // `.name` explicitly; the OpenAI SDK's is a real exported class instead.
  const isTimeout =
    (error as { name?: unknown })?.name === "RequestTimeoutError" || error instanceof APIConnectionTimeoutError;
  console.error(`${provider} API error`, {
    name: error instanceof Error ? error.name : typeof error,
    status,
    isTimeout,
    message: error instanceof Error ? error.message : String(error),
  });

  if (status === 429) {
    throw new AnalysisError("rate_limited_upstream", 429);
  }
  if (status === 503 || status === 504 || status === 408 || isTimeout) {
    throw new AnalysisError("upstream_unavailable", 503);
  }
  if (status !== undefined) {
    throw new AnalysisError("upstream_error", 502);
  }
  throw new AnalysisError("analysis_failed", 502);
}

async function analyseWithGemini(
  client: GoogleGenAI,
  request: AnalysisRequest,
  budget: Budget,
  researchNotes: string | null,
  timeoutMs: number
): Promise<string> {
  let interaction;
  try {
    interaction = await client.interactions.create(
      {
        model: budget.model,
        input: buildUserMessage(request, budget, researchNotes),
        system_instruction: `${SYSTEM_PROMPT}\n\n${OUTPUT_FORMAT_INSTRUCTIONS}`,
        generation_config: {
          thinking_level: budget.effort,
          max_output_tokens: budget.maxTokens,
        },
        response_format: { type: "text", mime_type: "application/json" },
      },
      { timeout: timeoutMs }
    );
  } catch (error) {
    throwForUpstreamError("Gemini", error);
  }

  if (interaction.status === "failed") {
    throw new AnalysisError("refused", 422);
  }

  return interaction.output_text ?? "";
}

/**
 * Groq's chat completions endpoint is OpenAI-compatible (base URL
 * https://api.groq.com/openai/v1), so the official `openai` SDK talks to it
 * directly -- no Groq-specific SDK needed. Used for every decision's
 * analysis step now, every complexity (see budget.ts): research still runs
 * on Gemini regardless of this provider.
 */
export async function analyseWithGroq(
  client: OpenAI,
  request: AnalysisRequest,
  budget: Budget,
  researchNotes: string | null,
  timeoutMs: number
): Promise<string> {
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model: budget.model,
        messages: [
          { role: "system", content: `${SYSTEM_PROMPT}\n\n${OUTPUT_FORMAT_INSTRUCTIONS}` },
          { role: "user", content: buildUserMessage(request, budget, researchNotes) },
        ],
        reasoning_effort: budget.effort,
        max_completion_tokens: budget.maxTokens,
      },
      { timeout: timeoutMs }
    );
  } catch (error) {
    throwForUpstreamError("Groq", error);
  }

  const choice = completion.choices[0];
  if (choice?.finish_reason === "content_filter") {
    throw new AnalysisError("refused", 422);
  }

  return choice?.message?.content ?? "";
}

/**
 * Recovers the JSON object from the model's text, despite being told to
 * return nothing else. Confirmed live: adding research notes to the prompt
 * (even on a fast model, well under any time or token ceiling) made this
 * model more likely to add a line of commentary before or after the object
 * -- a code fence anywhere in the text, not just wrapping the whole response,
 * and stray prose outside it. Tries, in order: the text as-is; a fence
 * anywhere in the text; the outermost {...} span. The result is still fully
 * re-validated against DecisionResponseSchema afterwards, so a wrong
 * extraction here fails safely rather than reaching the app.
 */
export function extractJsonObject(text: string): string {
  const trimmed = text.trim();

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
  if (fenced) return fenced[1]!;

  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start !== -1 && end > start) return trimmed.slice(start, end + 1);

  return trimmed;
}
