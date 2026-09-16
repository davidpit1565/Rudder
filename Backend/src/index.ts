import { createServer } from "node:http";
import { handle } from "./handler.js";
import { resolveClientKey } from "./rateLimit.js";
import { hasNoClientVerification } from "./attest.js";

/**
 * Standalone server. Behind TLS termination in production — the app refuses any
 * endpoint that is not https.
 */
const port = Number(process.env.PORT ?? 8787);

const server = createServer((req, res) => {
  const chunks: Buffer[] = [];
  let size = 0;

  req.on("data", (chunk: Buffer) => {
    size += chunk.length;
    if (size > 64_000) {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "payload_too_large" }));
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on("end", () => {
    if (res.writableEnded) return;

    const headers: Record<string, string | undefined> = {};
    for (const [key, value] of Object.entries(req.headers)) {
      headers[key.toLowerCase()] = Array.isArray(value) ? value[0] : value;
    }

    const clientKey = resolveClientKey(headers, req.socket.remoteAddress);
    const path = new URL(req.url ?? "/", "http://localhost").pathname;

    handle({
      method: req.method ?? "GET",
      path,
      headers,
      body: Buffer.concat(chunks).toString("utf8"),
      clientKey,
    })
      .then((response) => {
        res.writeHead(response.status, response.headers);
        res.end(response.body);
      })
      .catch(() => {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "internal_error" }));
      });
  });
});

// Bounds a slow-request style attack (many connections trickling a body in a
// few bytes at a time) rather than relying on whatever the platform's default
// happens to be. The payload cap above is small, so a well-behaved client has
// no reason to need longer than this.
server.requestTimeout = 30_000;
server.headersTimeout = 10_000;
server.keepAliveTimeout = 5_000;

server.listen(port, () => {
  if (!process.env.ANTHROPIC_API_KEY) {
    console.warn("ANTHROPIC_API_KEY is not set — analysis requests will fail.");
  }
  if (hasNoClientVerification()) {
    // Not a guess: with neither set, verifyClient() lets every request through,
    // so this is the one moment an operator who skipped the README will see it.
    console.warn(
      "No client verification is configured (DECIDE_CLIENT_TOKEN unset, " +
        "DECIDE_REQUIRE_ATTESTATION not 1) — this endpoint accepts requests from " +
        "anyone who finds it, bounded only by the rate and concurrency limits. " +
        "See the \"Known gap\" section in README.md before real production traffic."
    );
  }
  console.log(`RUDDER backend listening on :${port}`);
});
