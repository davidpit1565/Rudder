import type { GoogleGenAI } from "@google/genai";
import { DecisionResponseSchema, type AnalysisRequest, type WireResponse } from "./schema.js";
import { budgetFor } from "./budget.js";
import { SYSTEM_PROMPT, OUTPUT_FORMAT_INSTRUCTIONS, buildUserMessage } from "./prompt.js";
import { renderResearchNotes, runResearch } from "./research.js";
import { toWireResponse } from "./validate.js";

export class AnalysisError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "AnalysisError";
  }
}

/**
 * The whole pipeline for one decision: research what can be researched, then
 * analyse, then validate before anything is returned.
 */
export async function analyse(client: GoogleGenAI, request: AnalysisRequest): Promise<WireResponse> {
  const budget = budgetFor(request);

  let researchNotes: string | null = null;
  let retrievedUrls = new Map<string, string>();

  try {
    const research = await runResearch(client, request, budget);
    if (research) {
      researchNotes = renderResearchNotes(research);
      retrievedUrls = research.retrievedUrls;
    }
  } catch {
    // Research is best-effort: the analysis proceeds and says what it could not
    // verify, rather than failing the whole decision.
    researchNotes = null;
  }

  let interaction;
  try {
    interaction = await client.interactions.create({
      model: budget.model,
      input: buildUserMessage(request, budget, researchNotes),
      system_instruction: `${SYSTEM_PROMPT}\n\n${OUTPUT_FORMAT_INSTRUCTIONS}`,
      generation_config: {
        thinking_level: budget.effort,
        max_output_tokens: budget.maxTokens,
      },
      response_format: { type: "text", mime_type: "application/json" },
    });
  } catch (error) {
    // Server-side only, never sent to the client: just enough to diagnose an
    // upstream failure (name, HTTP status, the provider's own message)
    // without logging the request, the response, or anything from
    // process.env. Duck-typed on `.status` rather than an imported error
    // class, since that's the one property the SDK's errors are documented
    // to carry consistently.
    const status = typeof (error as { status?: unknown })?.status === "number"
      ? (error as { status: number }).status
      : undefined;
    console.error("Gemini API error", {
      name: error instanceof Error ? error.name : typeof error,
      status,
      message: error instanceof Error ? error.message : String(error),
    });

    if (status === 429) {
      throw new AnalysisError("rate_limited_upstream", 429);
    }
    if (status === 503 || status === 504 || status === 408) {
      throw new AnalysisError("upstream_unavailable", 503);
    }
    if (status !== undefined) {
      throw new AnalysisError("upstream_error", 502);
    }
    throw new AnalysisError("analysis_failed", 502);
  }

  if (interaction.status === "failed") {
    throw new AnalysisError("refused", 422);
  }

  const text = interaction.output_text ?? "";

  let rawOutput: unknown;
  try {
    rawOutput = JSON.parse(extractJsonObject(text));
  } catch {
    // Diagnostic only -- status and token counts, never the decision content
    // itself. `max_output_tokens` is a hard cap that includes thinking
    // tokens on Gemini, unlike the previous provider, so a budget that looks
    // generous can still starve the actual JSON text; this is what would show it.
    console.error("Gemini response was not valid JSON", {
      status: interaction.status,
      textLength: text.length,
      totalOutputTokens: interaction.usage?.total_output_tokens,
      totalThoughtTokens: interaction.usage?.total_thought_tokens,
    });
    throw new AnalysisError("unparseable_response", 502);
  }

  // Re-validated here rather than trusted: nothing about the prompted-JSON
  // approach above guarantees the shape, so this is not redundant -- it is
  // the only real enforcement of the contract before anything reaches the app.
  const parsed = DecisionResponseSchema.safeParse(rawOutput);
  if (!parsed.success) {
    console.error("Gemini response was valid JSON but failed the contract", {
      status: interaction.status,
      issues: parsed.error.issues.slice(0, 5).map((issue) => ({ path: issue.path.join("."), message: issue.message })),
    });
    throw new AnalysisError("unparseable_response", 502);
  }

  return toWireResponse(parsed.data, request, budget, retrievedUrls);
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
