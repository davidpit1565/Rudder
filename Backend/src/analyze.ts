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
    throw new AnalysisError("unparseable_response", 502);
  }

  // Re-validated here rather than trusted: nothing about the prompted-JSON
  // approach above guarantees the shape, so this is not redundant -- it is
  // the only real enforcement of the contract before anything reaches the app.
  const parsed = DecisionResponseSchema.safeParse(rawOutput);
  if (!parsed.success) {
    throw new AnalysisError("unparseable_response", 502);
  }

  return toWireResponse(parsed.data, request, budget, retrievedUrls);
}

/** Strips an accidental markdown code fence, in case the model adds one
 * despite being told not to. */
function extractJsonObject(text: string): string {
  const trimmed = text.trim();
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  return fenced ? fenced[1]! : trimmed;
}
