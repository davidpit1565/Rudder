import type { GoogleGenAI } from "@google/genai";
import type { AnalysisRequest } from "./schema.js";
import type { Budget } from "./budget.js";
import { buildResearchPrompt } from "./prompt.js";
import { SYSTEM_PROMPT } from "./prompt.js";

export interface ResearchResult {
  /** The model's brief, passed into the analysis call. */
  notes: string;
  /** Every URL actually returned by the search tool. Nothing else may be cited. */
  retrievedUrls: Map<string, string>;
  searchesUsed: number;
}

/**
 * Phase one: find what can be found.
 *
 * Runs only when the decision justifies it. The URLs collected here are the
 * allow-list for the analysis phase, so a fabricated citation cannot survive.
 *
 * Unlike the previous provider, Gemini's Google Search tool has no per-call
 * cap on how many searches it runs -- it decides that itself within one
 * request/response, so budget.maxSearches is only ever used here to turn
 * research on or off, and as a number put in front of the model as an
 * instruction (buildResearchPrompt), not as an enforced ceiling.
 */
export async function runResearch(
  client: GoogleGenAI,
  request: AnalysisRequest,
  budget: Budget
): Promise<ResearchResult | null> {
  if (budget.maxSearches === 0) return null;

  const interaction = await client.interactions.create({
    model: budget.model,
    input: buildResearchPrompt(request, budget),
    system_instruction: SYSTEM_PROMPT,
    generation_config: {
      thinking_level: budget.effort,
      max_output_tokens: 4000,
    },
    tools: [{ type: "google_search" }],
  });

  const retrievedUrls = new Map<string, string>();
  let searchesUsed = 0;

  for (const step of interaction.steps ?? []) {
    if (step.type === "google_search_call") {
      searchesUsed += 1;
    } else if (step.type === "model_output") {
      for (const block of step.content ?? []) {
        if (block.type !== "text") continue;
        for (const annotation of block.annotations ?? []) {
          if (annotation.type === "url_citation" && annotation.url) {
            retrievedUrls.set(annotation.url, annotation.title ?? annotation.url);
          }
        }
      }
    }
  }

  return { notes: (interaction.output_text ?? "").trim(), retrievedUrls, searchesUsed };
}

/** Renders the brief and its sources for the analysis prompt. */
export function renderResearchNotes(research: ResearchResult): string {
  const sources = [...research.retrievedUrls.entries()]
    .map(([url, title]) => `- ${title} — ${url}`)
    .join("\n");

  return [
    research.notes || "(nothing usable was found)",
    "",
    sources ? `SOURCES RETRIEVED (cite only these URLs):\n${sources}` : "NO SOURCES WERE RETRIEVED. Every sourceUrl must be null and verified must be false.",
  ].join("\n");
}
