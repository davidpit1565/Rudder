import { strict as assert } from "node:assert";
import test from "node:test";
import type { GoogleGenAI } from "@google/genai";
import { runResearch } from "../research.js";
import { budgetFor } from "../budget.js";
import { AnalysisRequestSchema, SCHEMA_VERSION } from "../schema.js";

function makeRequest(overrides: Record<string, unknown> = {}) {
  return AnalysisRequestSchema.parse({
    schemaVersion: SCHEMA_VERSION,
    prompt: "Something to research",
    category: "other",
    complexity: "medium",
    researchLevel: "light",
    maximumResearchCalls: 2,
    maximumSources: 10,
    questionsAlreadyAsked: 0,
    questionCeiling: 3,
    ...overrides,
  });
}

function textStepWithCitation(url: string) {
  return {
    type: "model_output" as const,
    content: [
      {
        type: "text" as const,
        text: `The current price is noted here.`,
        annotations: [{ type: "url_citation" as const, url, title: url, startIndex: 0, endIndex: 1 }],
      },
    ],
  };
}

function fakeClient(create: () => Promise<{ output_text: string; steps: unknown[] }>): GoogleGenAI {
  return { interactions: { create } } as unknown as GoogleGenAI;
}

test("no searches budgeted means no call to the model at all", async () => {
  const request = makeRequest({ researchLevel: "none", maximumResearchCalls: 0, complexity: "simple" });
  const budget = budgetFor(request);
  let called = false;
  const client = fakeClient(async () => {
    called = true;
    throw new Error("should not be called");
  });

  const result = await runResearch(client, request, budget);
  assert.equal(result, null);
  assert.equal(called, false);
});

test("a normal research call reads back the notes and cited sources", async () => {
  const request = makeRequest();
  const budget = budgetFor(request);
  let callCount = 0;
  const client = fakeClient(async () => {
    callCount += 1;
    return {
      output_text: "Found the current price.",
      steps: [{ type: "google_search_call", arguments: { queries: ["current price"] } }, textStepWithCitation("https://example.com/a")],
    };
  });

  const result = await runResearch(client, request, budget);
  assert.equal(callCount, 1);
  assert.equal(result?.notes, "Found the current price.");
  assert.equal(result?.searchesUsed, 1);
  assert.equal(result?.retrievedUrls.size, 1);
  assert.equal(result?.retrievedUrls.get("https://example.com/a"), "https://example.com/a");
});

test("sources from more than one search step are all collected", async () => {
  const request = makeRequest();
  const budget = budgetFor(request);
  const client = fakeClient(async () => ({
    output_text: "Two facts, two sources.",
    steps: [
      { type: "google_search_call", arguments: { queries: ["a"] } },
      textStepWithCitation("https://example.com/1"),
      { type: "google_search_call", arguments: { queries: ["b"] } },
      textStepWithCitation("https://example.com/2"),
    ],
  }));

  const result = await runResearch(client, request, budget);
  assert.equal(result?.searchesUsed, 2);
  assert.equal(result?.retrievedUrls.size, 2);
});
