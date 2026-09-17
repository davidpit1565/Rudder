import type { IncomingMessage } from "node:http";

export class PayloadTooLargeError extends Error {}

/**
 * Reads a request body up to `maxBytes`, rejecting as soon as that ceiling is
 * crossed rather than after buffering the whole stream. Shared by both hosts
 * (`src/index.ts`'s standalone server and `api/index.ts`'s Vercel Function) so
 * neither can hold an unbounded body in memory before `handle()`'s own,
 * separate JSON-body size check ever runs.
 *
 * Deliberately does not call `request.destroy()` itself: on a real
 * `IncomingMessage`, destroying the socket before a response has been written
 * to it resets the connection instead of delivering a 413 — the caller must
 * write its error response first, then destroy.
 */
export function readBody(request: IncomingMessage, maxBytes: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let rejected = false;
    request.on("data", (chunk: Buffer) => {
      if (rejected) return;
      size += chunk.length;
      if (size > maxBytes) {
        rejected = true;
        reject(new PayloadTooLargeError());
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (!rejected) resolve(Buffer.concat(chunks).toString("utf8"));
    });
    request.on("error", (error) => {
      if (!rejected) reject(error);
    });
  });
}
