import { strict as assert } from "node:assert";
import test from "node:test";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { FollowUpRequestSchema, FollowUpResponseSchema, SCHEMA_VERSION } from "../schema.js";

const here = dirname(fileURLToPath(import.meta.url));

test("the follow-up request contract accepts what the app actually sends", () => {
  const parsed = FollowUpRequestSchema.safeParse({
    schemaVersion: SCHEMA_VERSION,
    originalPrompt: "MacBook Air or MacBook Pro for photo editing?",
    decisionContext: "Recommended the MacBook Air for portability.",
    history: [{ question: "Is it fast enough for Lightroom?", answer: "Yes, for typical batch edits." }],
    question: "What about exporting 4K video occasionally?",
    locale: "en_GB",
  });
  assert.ok(parsed.success);
});

test("an old schema version is refused rather than misread", () => {
  const parsed = FollowUpRequestSchema.safeParse({
    schemaVersion: 0,
    originalPrompt: "MacBook Air or MacBook Pro?",
    decisionContext: "Recommended the Air.",
    question: "Why not the Pro?",
  });
  assert.equal(parsed.success, false);
});

test("history defaults to empty rather than being required", () => {
  const parsed = FollowUpRequestSchema.parse({
    schemaVersion: SCHEMA_VERSION,
    originalPrompt: "MacBook Air or MacBook Pro?",
    decisionContext: "Recommended the Air.",
    question: "Why not the Pro?",
  });
  assert.deepEqual(parsed.history, []);
});

test("a full follow-up response serialises to the shape the iPhone app decodes", () => {
  const response = FollowUpResponseSchema.parse({
    answer: "The Air handles occasional 4K exports fine, just slower than the Pro would.",
    needsResearch: false,
    suggestedNewDecisionPrompt: null,
    durablePreference: null,
  });

  assert.deepEqual(Object.keys(response).sort(), [
    "answer", "durablePreference", "needsResearch", "suggestedNewDecisionPrompt",
  ]);

  // Written out so the Swift side decodes the same bytes this server produces.
  const fixturePath = join(here, "../../../Packages/RudderKit/Tests/RudderCoreTests/Fixtures/followup_contract.json");
  mkdirSync(dirname(fixturePath), { recursive: true });
  writeFileSync(fixturePath, JSON.stringify(response, null, 2) + "\n");
});

test("a response carrying a research redirect and a durable preference still validates", () => {
  const response = FollowUpResponseSchema.parse({
    answer: "That really depends on current pricing, which I don't have in front of me.",
    needsResearch: true,
    suggestedNewDecisionPrompt: "Compare MacBook Air vs MacBook Pro current pricing for photo editing use.",
    durablePreference: { statement: "You prioritize portability over raw performance." },
  });
  assert.equal(response.needsResearch, true);
  assert.ok(response.suggestedNewDecisionPrompt);
  assert.ok(response.durablePreference?.statement);
});
