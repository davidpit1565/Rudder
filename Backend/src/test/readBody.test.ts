import { strict as assert } from "node:assert";
import test from "node:test";
import { EventEmitter } from "node:events";
import type { IncomingMessage } from "node:http";
import { readBody, PayloadTooLargeError } from "../readBody.js";

/** A minimal stand-in for IncomingMessage: just the event surface readBody() uses. */
class FakeRequest extends EventEmitter {}

test("a body within the ceiling resolves with its full contents", async () => {
  const req = new FakeRequest();
  const promise = readBody(req as unknown as IncomingMessage, 64_000);
  req.emit("data", Buffer.from("hello "));
  req.emit("data", Buffer.from("world"));
  req.emit("end");
  assert.equal(await promise, "hello world");
});

test("a body over the ceiling is rejected as soon as it is crossed, not after buffering the whole stream", async () => {
  const req = new FakeRequest();
  const promise = readBody(req as unknown as IncomingMessage, 64_000);

  // One chunk already over the ceiling -- must reject on this chunk, never
  // waiting for "end" to see the whole (unbounded) stream first.
  req.emit("data", Buffer.alloc(70_000, "a"));

  await assert.rejects(promise, PayloadTooLargeError);
});

test("readBody itself never destroys the request -- that is the caller's job, after it has written a response", async () => {
  const req = new FakeRequest();
  const promise = readBody(req as unknown as IncomingMessage, 10);
  req.emit("data", Buffer.alloc(20, "a"));
  await assert.rejects(promise, PayloadTooLargeError);
  // No destroy() method exists on this fake at all -- if readBody called it,
  // this test would throw synchronously inside the "data" handler.
});

test("a body exactly at the ceiling is accepted", async () => {
  const req = new FakeRequest();
  const promise = readBody(req as unknown as IncomingMessage, 10);
  req.emit("data", Buffer.alloc(10, "a"));
  req.emit("end");
  assert.equal((await promise).length, 10);
});
