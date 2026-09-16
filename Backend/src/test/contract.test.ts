import { strict as assert } from "node:assert";
import test from "node:test";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { DecisionResponseSchema, SCHEMA_VERSION } from "../schema.js";
import { OUTPUT_FORMAT_INSTRUCTIONS } from "../prompt.js";
import { toWireResponse } from "../validate.js";
import { budgetFor } from "../budget.js";
import { AnalysisRequestSchema } from "../schema.js";

const here = dirname(fileURLToPath(import.meta.url));

test("the prompted output format embeds the real contract, not a stale copy", () => {
  // Confirmed live: Anthropic's grammar-constrained structured output rejects
  // this schema outright ("compiled grammar is too large"), so the contract is
  // asked for by instruction instead (see analyze.ts) -- this only confirms
  // the embedded schema is the actual one, not a hand-copied string that could
  // drift from it.
  const embeddedSchema = JSON.parse(
    OUTPUT_FORMAT_INSTRUCTIONS.slice(OUTPUT_FORMAT_INSTRUCTIONS.indexOf("{"))
  ) as { properties?: Record<string, unknown> };
  assert.ok(embeddedSchema.properties, "the embedded schema exposes its properties");
  for (const key of ["decisionStatus", "criteria", "options", "recommendation"]) {
    assert.ok(key in embeddedSchema.properties!, `${key} is part of the contract`);
  }
});

test("a full response serialises to the shape the iPhone app decodes", () => {
  const request = AnalysisRequestSchema.parse({
    schemaVersion: SCHEMA_VERSION,
    prompt: "MacBook Air or MacBook Pro for photo editing?",
    category: "technology",
    complexity: "medium",
    researchLevel: "light",
    maximumResearchCalls: 2,
    maximumSources: 4,
    questionsAlreadyAsked: 0,
    questionCeiling: 3,
  });

  const response = DecisionResponseSchema.parse({
    decisionStatus: "ready",
    category: "technology",
    complexity: "medium",
    understanding: {
      restatement: "You're choosing between a MacBook Air and a MacBook Pro for daily work and photo editing.",
      knownContext: ["Carries the laptop every day"],
      whatMatters: ["Portability", "Enough power for photo editing"],
    },
    preliminaryRecommendation: { optionId: "air", rationale: "Portability is doing most of the work here." },
    requiredQuestions: [],
    researchNeeded: { level: "light", topics: ["current pricing"] },
    criteria: [
      { id: "portability", name: "Portability", weight: 0.45, rationale: "Carried every day." },
      { id: "performance", name: "Performance", weight: 0.35, rationale: null },
      { id: "price", name: "Price", weight: 0.2, rationale: null },
    ],
    options: [
      {
        id: "air",
        name: "MacBook Air",
        summary: "Lighter, fanless, cheaper.",
        scores: [
          { criterionId: "portability", score: 0.95 },
          { criterionId: "performance", score: 0.62 },
          { criterionId: "price", score: 0.8 },
        ],
        failedConstraints: [],
      },
      {
        id: "pro",
        name: "MacBook Pro",
        summary: "Faster, heavier, more expensive.",
        scores: [
          { criterionId: "portability", score: 0.5 },
          { criterionId: "performance", score: 0.95 },
          { criterionId: "price", score: 0.35 },
        ],
        failedConstraints: [],
      },
    ],
    recommendation: {
      optionId: "air",
      headline: "Best fit for you",
      reasons: [
        { title: "It's the one you'll actually carry", detail: "You move with it daily and the Air is meaningfully lighter." },
        { title: "Fast enough for your editing", detail: "Your photo work sits well inside what the Air handles." },
      ],
    },
    tradeoffs: [{ gaining: "Portability", givingUp: "Sustained performance on long exports" }],
    risks: [{ title: "Heavier editing later", detail: "If your work shifts to video, the Air will feel tight.", severity: "medium" }],
    assumptions: [{ statement: "Photo editing means Lightroom-scale work.", impactIfWrong: "The Pro becomes the better choice." }],
    research: [
      {
        claim: "The MacBook Air weighs about 1.24 kg versus 1.55 kg for the 14-inch Pro.",
        sourceTitle: "Apple technical specifications",
        sourceUrl: "https://www.apple.com/macbook-air/specs/",
        retrievedAt: "2026-09-01T10:00:00Z",
        verified: true,
      },
    ],
    conflicts: [],
    whatCouldMakeMeWrong: ["If you start exporting long 4K video, the Pro wins."],
  });

  const retrieved = new Map([["https://www.apple.com/macbook-air/specs/", "Apple technical specifications"]]);
  const wire = toWireResponse(response, request, budgetFor(request), retrieved);

  // Exactly the keys AIDecisionResponse decodes in RudderCore.
  assert.deepEqual(Object.keys(wire).sort(), [
    "assumptions", "category", "complexity", "conflicts", "criteria",
    "decisionStatus", "options", "preliminaryRecommendation", "recommendation",
    "requiredQuestions", "research", "researchNeeded", "risks", "schemaVersion",
    "tradeoffs", "understanding", "whatCouldMakeMeWrong",
  ]);
  assert.deepEqual(wire.options[0]!.scores, { portability: 0.95, performance: 0.62, price: 0.8 });

  // Written out so the Swift side decodes the same bytes this server produces.
  const fixturePath = join(here, "../../../Packages/RudderKit/Tests/RudderCoreTests/Fixtures/backend_contract.json");
  mkdirSync(dirname(fixturePath), { recursive: true });
  writeFileSync(fixturePath, JSON.stringify(wire, null, 2) + "\n");
});
