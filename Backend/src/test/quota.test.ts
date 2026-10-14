import { strict as assert } from "node:assert";
import test from "node:test";
import {
  checkDeepDecisionQuota,
  refundDeepDecisionQuota,
  peekDeepDecisionQuota,
  resetDeepDecisionQuota,
  checkDailyQuota,
  refundDailyQuota,
  peekDailyQuota,
  resetDailyQuota,
} from "../quota.js";

test.beforeEach(() => {
  resetDeepDecisionQuota();
  resetDailyQuota();
});

test("the first N spends within the limit are allowed", async () => {
  const now = Date.now();
  for (let i = 1; i <= 3; i++) {
    const decision = await checkDeepDecisionQuota("install-a", 3, now);
    assert.equal(decision.allowed, true, `spend ${i} should be allowed`);
    assert.equal(decision.used, i);
  }
});

test("a spend beyond the limit is refused", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-b", 3, now);
  await checkDeepDecisionQuota("install-b", 3, now);
  await checkDeepDecisionQuota("install-b", 3, now);
  const fourth = await checkDeepDecisionQuota("install-b", 3, now);
  assert.equal(fourth.allowed, false);
  assert.equal(fourth.used, 4);
});

test("different installs never share a bucket", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-c", 1, now);
  const other = await checkDeepDecisionQuota("install-d", 1, now);
  assert.equal(other.allowed, true);
});

test("a refund gives back exactly one spend", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-e", 1, now);
  await refundDeepDecisionQuota("install-e", now);
  const again = await checkDeepDecisionQuota("install-e", 1, now);
  assert.equal(again.allowed, true, "the refunded spend should be available again");
});

test("with the shipped default of 0, the first spend is still free, the second is not", async () => {
  const now = Date.now();
  const first = await checkDeepDecisionQuota("install-g", 0, now);
  assert.equal(first.allowed, true, "the one unconditional free decision must go through");
  const second = await checkDeepDecisionQuota("install-g", 0, now);
  assert.equal(second.allowed, false, "a recurring free allowance must not exist beyond the first");
});

test("a new calendar month starts a fresh count", async () => {
  const monthOne = Date.UTC(2026, 0, 15);
  const monthTwo = Date.UTC(2026, 1, 3);
  await checkDeepDecisionQuota("install-f", 1, monthOne);
  const nextMonth = await checkDeepDecisionQuota("install-f", 1, monthTwo);
  assert.equal(nextMonth.allowed, true);
});

test("peeking the monthly quota never spends a unit", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-peek-month", 2, now);
  const peekedOnce = await peekDeepDecisionQuota("install-peek-month", 2, now);
  assert.equal(peekedOnce.used, 1);
  const peekedTwice = await peekDeepDecisionQuota("install-peek-month", 2, now);
  assert.equal(peekedTwice.used, 1, "peeking twice must not increment the count itself");
  // The real spend still counts normally afterwards.
  const second = await checkDeepDecisionQuota("install-peek-month", 2, now);
  assert.equal(second.used, 2);
});

// --- Daily quota buckets (checkDailyQuota/refundDailyQuota/peekDailyQuota) ---

test("daily: the first N spends within the limit are allowed", async () => {
  const now = Date.now();
  for (let i = 1; i <= 3; i++) {
    const decision = await checkDailyQuota("medium-free", "install-d1", 3, now);
    assert.equal(decision.allowed, true, `spend ${i} should be allowed`);
    assert.equal(decision.used, i);
  }
});

test("daily: a spend beyond the limit is refused, with no free pass for the first unit", async () => {
  const now = Date.now();
  // Unlike the monthly complex quota, a daily bucket has no "first spend is
  // always free" exception -- a limit of 0 must refuse immediately.
  const first = await checkDailyQuota("medium-free", "install-d2", 0, now);
  assert.equal(first.allowed, false);
});

test("daily: different buckets for the same install never share a count", async () => {
  const now = Date.now();
  await checkDailyQuota("medium-free", "install-d3", 1, now);
  const proBucket = await checkDailyQuota("medium-pro", "install-d3", 15, now);
  assert.equal(proBucket.allowed, true, "medium-pro has its own count, unaffected by medium-free's");
  assert.equal(proBucket.used, 1);
});

test("daily: different installs never share a bucket", async () => {
  const now = Date.now();
  await checkDailyQuota("medium-free", "install-d4", 1, now);
  const other = await checkDailyQuota("medium-free", "install-d5", 1, now);
  assert.equal(other.allowed, true);
});

test("daily: a refund gives back exactly one spend", async () => {
  const now = Date.now();
  await checkDailyQuota("complex-pro", "install-d6", 1, now);
  await refundDailyQuota("complex-pro", "install-d6", now);
  const again = await checkDailyQuota("complex-pro", "install-d6", 1, now);
  assert.equal(again.allowed, true, "the refunded spend should be available again");
});

test("daily: a new UTC day starts a fresh count", async () => {
  const dayOne = Date.UTC(2026, 0, 15, 23, 0, 0);
  const dayTwo = Date.UTC(2026, 0, 16, 1, 0, 0);
  await checkDailyQuota("medium-free", "install-d7", 1, dayOne);
  const nextDay = await checkDailyQuota("medium-free", "install-d7", 1, dayTwo);
  assert.equal(nextDay.allowed, true);
});

test("daily: resetsAt is the next UTC midnight", async () => {
  const now = Date.UTC(2026, 0, 15, 13, 30, 0);
  const decision = await checkDailyQuota("medium-free", "install-d8", 5, now);
  assert.equal(decision.resetsAt, new Date(Date.UTC(2026, 0, 16, 0, 0, 0)).toISOString());
});

test("daily: peeking never spends a unit", async () => {
  const now = Date.now();
  await checkDailyQuota("medium-pro", "install-d9", 15, now);
  const peekedOnce = await peekDailyQuota("medium-pro", "install-d9", 15, now);
  assert.equal(peekedOnce.used, 1);
  const peekedTwice = await peekDailyQuota("medium-pro", "install-d9", 15, now);
  assert.equal(peekedTwice.used, 1, "peeking twice must not increment the count itself");
  const second = await checkDailyQuota("medium-pro", "install-d9", 15, now);
  assert.equal(second.used, 2);
});

test("daily: peeking an install that never spent reports zero, not an error", async () => {
  const peeked = await peekDailyQuota("medium-free", "install-never-spent", 5);
  assert.equal(peeked.used, 0);
  assert.equal(peeked.allowed, true);
});
