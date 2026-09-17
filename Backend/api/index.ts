import type { IncomingMessage, ServerResponse } from "node:http";
import { handle } from "../src/handler.js";
import { resolveClientKey } from "../src/rateLimit.js";
import { hasUnreliableRateLimiting } from "../src/redis.js";
import { readBody, PayloadTooLargeError } from "../src/readBody.js";

if (hasUnreliableRateLimiting()) {
  // Runs once per cold start, not per request -- loud enough to notice
  // without spamming the logs on a warm instance.
  console.warn(
    "Redis is not configured (DECIDE_KV_KV_REST_API_URL/_TOKEN unset) -- on " +
      "Vercel, requests can land on a fresh instance each time, so the rate " +
      "and concurrency limits are not actually enforced. See README.md."
  );
}

/**
 * Vercel's zero-config Node.js runtime for a bare /api file uses the
 * Node-style (request, response) signature, not the Web Fetch API --
 * `request.headers` here is a plain object, not a Headers instance, and
 * the body is a raw stream. This only translates that shape into
 * handle()'s {method, path, headers, body, clientKey}, which the
 * standalone server in src/index.ts also uses. Same handler, same rules,
 * two hosts.
 *
 * There is no raw socket here -- Vercel Functions are only ever reached
 * through Vercel's own edge network, so there is no separate origin address
 * for x-forwarded-for to be spoofed against. DECIDE_TRUST_PROXY=1 is the
 * correct setting for this deployment target specifically, not a shortcut.
 */
export default async function vercelHandler(
  request: IncomingMessage,
  response: ServerResponse,
): Promise<void> {
  const headers: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(request.headers)) {
    headers[key.toLowerCase()] = Array.isArray(value) ? value.join(", ") : value;
  }

  const trustsProxy = process.env.DECIDE_TRUST_PROXY === "1";
  const clientKey = resolveClientKey(headers, undefined, trustsProxy);
  const path = new URL(request.url ?? "/", "http://localhost").pathname;
  const method = request.method ?? "GET";

  let body: string;
  try {
    body = method === "GET" || method === "HEAD" ? "" : await readBody(request, 64_000);
  } catch (error) {
    if (error instanceof PayloadTooLargeError) {
      response.statusCode = 413;
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify({ error: "payload_too_large" }));
      request.destroy();
      return;
    }
    throw error;
  }

  const result = await handle({ method, path, headers, body, clientKey });

  response.statusCode = result.status;
  for (const [key, value] of Object.entries(result.headers)) {
    response.setHeader(key, value);
  }
  response.end(result.body);
}
