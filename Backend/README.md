# RUDDER backend

One endpoint. It exists so the iPhone app never has to hold a model provider
credential, and so the cost of a decision can be controlled somewhere the user
cannot tamper with.

```
iPhone  ->  POST /v1/decisions/analyze  ->  Anthropic API  ->  validated JSON  ->  iPhone
```

## What it does

1. **Validates the request** against the shared contract (`src/schema.ts`) before
   anything is spent.
2. **Rate limits** per client — a short burst window and a much longer daily
   one — and optionally requires a bearer token.
3. **Caps concurrency** globally, so however many identities arrive at once,
   only a bounded number can be spending money at the same time.
4. **Sets a budget** from the decision's complexity (`src/budget.ts`): effort
   level, token ceiling, and how many web searches the decision is worth. A
   trivial decision buys no research at all.
5. **Researches** what can be researched (`src/research.ts`), recording every URL
   the search tool actually returned.
6. **Analyses** with a required output schema (`src/analyze.ts`), so the response
   is structured rather than parsed out of prose.
7. **Validates again** (`src/validate.ts`) — this is the part that matters:
   - a citation whose URL was not actually retrieved is stripped and marked
     unverified, so a fabricated source cannot reach the user;
   - a recommendation pointing at an option that does not exist is removed;
   - questions beyond the app's budget, or that the system could research itself,
     are dropped;
   - the model cannot talk its way into a bigger research budget;
   - any confidence percentage in user-facing text is removed. Decision strength
     is computed on the device by re-running the analysis under varied
     priorities — a number from the model would be invented certainty.

## Running it

```bash
cp .env.example .env     # add your ANTHROPIC_API_KEY
npm install
npm test                 # 80 tests, no network, no spend
npm run build && npm start
```

The app expects `RudderAPIBaseURL` (in `Config/Shared.xcconfig`) to point at this
service over HTTPS. Anything that is not https is ignored by the app.

## Deploying

The handler in `src/handler.ts` is framework-agnostic — `{method, path, headers,
body, clientKey}` in, `{status, headers, body}` out — so it drops into a
serverless function or sits behind the standalone server in `src/index.ts`.
Whatever runs it must terminate TLS.

Set in the environment, never in code:

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | The only credential. Never leaves the server. |
| `DECIDE_RATE_LIMIT`, `DECIDE_RATE_WINDOW_SECONDS` | Requests per burst window, per client. |
| `DECIDE_DAILY_LIMIT` | Requests per 24h, per client — bounds sustained abuse the burst window alone does not. |
| `DECIDE_MAX_CONCURRENT_ANALYSES` | How many analyses may run at once, across every client. |
| `DECIDE_TRUST_PROXY` | `1` only if a proxy you control sets `x-forwarded-for` *and* the origin is not otherwise reachable. Read `.env.example` before setting this — wrong in either direction is a real problem, not a formality. |
| `DECIDE_CLIENT_TOKEN` | Optional bearer token. Coarse filter only — see below. |
| `DECIDE_REQUIRE_ATTESTATION` | `1` refuses every request until App Attest is implemented. |
| `DECIDE_KV_KV_REST_API_URL`, `DECIDE_KV_KV_REST_API_TOKEN` | Upstash Redis REST credentials (`src/redis.ts`). Required for the rate and concurrency limits to actually hold — see below. The doubled "KV" is not a typo, just what Vercel's Upstash integration produced for this project's variable prefix. |
| `DECIDE_FREE_DEEP_DECISIONS_PER_MONTH` | How many "complex" decisions one install may spend without a verified Pro transaction, per calendar month (`src/quota.ts`). Defaults to 1, mirroring `FeatureAccess.freeDeepDecisionsPerMonth` in `App/App/AppEnvironment.swift` — the two aren't wired together, so keep them in sync by hand if either changes. Set low deliberately: at bootstrap-stage volume this is the most direct lever on Free's own cost. |
| `DECIDE_BUNDLE_ID` | The app's bundle identifier, checked against every Pro transaction (`src/appStoreVerify.ts`). Defaults to `com.rudder.app` — confirm that's actually the Rudder target's `PRODUCT_BUNDLE_IDENTIFIER` and set this explicitly if it ever differs. |
| `DECIDE_APPLE_ROOT_FINGERPRINT` | Overrides the pinned Apple Root CA - G3 fingerprint `src/appStoreVerify.ts` verifies every transaction chain against. Only ever set in tests; production should use the hardcoded default. |
| `DECIDE_MONTHLY_FREE_SPEND_CEILING_USD` | The absolute ceiling on total estimated Free-tier AI spend per calendar month, across every install (`src/spendCeiling.ts`). Defaults to $12 -- kept tight at bootstrap-stage volume, since this plus fixed hosting cost is the real monthly floor a small payer base has to outrun. Raise it once real conversion data justifies carrying more cost. Never applies to a verified Pro transaction. |

### Why the limits need Redis on a serverless host

`checkRateLimit`, `checkDailyLimit` and the concurrency cap were originally
in-process counters. That is fine behind a single long-lived process, but on
Vercel it is not a corner case that gets hit occasionally — confirmed live,
eight consecutive requests to the same endpoint each landed on a distinct
execution instance with its own memory, so an in-process counter never
accumulated a count at all. Without Redis configured, the limits are
effectively not enforced on this host, whatever their configured values say.

`src/redis.ts` talks to Upstash's REST API directly (a single `fetch` per
pipeline call, no SDK dependency) whenever `DECIDE_KV_KV_REST_API_URL` and
`DECIDE_KV_KV_REST_API_TOKEN` are set, and every limiter falls back to the
original in-process counters otherwise — which is exactly right for local
development and for the test suite, where there is only ever one process.
`hasUnreliableRateLimiting()` warns once per cold start on Vercel if Redis
is not configured, so this is never a silent gap.

If Redis itself is unreachable, every limiter **fails closed** — a request is
treated as rate-limited or refused a concurrency slot rather than allowed
through unconditionally. This trades a temporary outage during a genuine
Redis incident for keeping the cost-exposure protection intact; it does not
fail open just because the failure would be inconvenient to hit.

### First production deployment

Nothing here needs a framework, a container, or new infrastructure: the
existing `npm run build && npm start` already produces exactly what
production runs. Any host that can run a persistent Node process and put
real TLS in front of it — a small VPS behind a reverse proxy, or a
platform-as-a-service that terminates HTTPS for you — is enough.

1. **Runtime.** Node 20 or newer (`engines` in `package.json`); CI runs 22, so
   prefer 22 to run on exactly what was tested.
2. **Build and start.**
   ```bash
   npm ci
   npm run build     # tsc -> dist/
   npm start         # node dist/index.js
   ```
   `PORT` (default `8787`) is the only thing the process itself reads for its
   listen address.
3. **TLS.** `src/index.ts` is a plain `http.createServer` — it does not
   terminate TLS itself. Something in front of it must: the platform's own
   HTTPS layer, or a reverse proxy (Caddy, nginx) with a real certificate.
   The iOS app refuses anything that isn't `https://` with a non-empty host
   (verified in `AppConfiguration.swift`), so a plain-HTTP deployment simply
   won't be reachable from the app at all.
4. **Health check.** `GET /healthz` — no auth, no rate limit, no model call,
   answers `{"status":"ok"}` immediately. Point the platform's own health
   probe at this path.
5. **Secrets.** Set `ANTHROPIC_API_KEY` (and `DECIDE_CLIENT_TOKEN`, if used)
   through the platform's secret/environment store — never in a committed
   file. `.env` is git-ignored; only `.env.example`, which holds no real
   value, is tracked.
6. **Proxy configuration.** If the platform puts its own load balancer or
   CDN in front of this process, set `DECIDE_TRUST_PROXY=1` *and* confirm
   the process itself is not separately reachable from the public internet
   (most PaaS platforms guarantee this by construction; a self-managed VPS
   needs an explicit firewall rule). If you're not certain both are true,
   leave it unset — an overly strict shared rate-limit bucket is a much
   smaller problem than a forgeable one.
7. **Rate, daily and concurrency limits.** Ship with the defaults
   (`DECIDE_RATE_LIMIT=20`, `DECIDE_DAILY_LIMIT=200`,
   `DECIDE_MAX_CONCURRENT_ANALYSES=5`) unless you have a specific reason to
   tighten them for a first controlled rollout — they are safe starting
   points, not requirements to change.
8. **Timeouts.** `requestTimeout` / `headersTimeout` / `keepAliveTimeout` are
   set in `src/index.ts` and apply as long as this process is what's
   actually listening. They do **not** apply if you instead port `handle()`
   into a serverless function (still possible — it's framework-agnostic by
   design — but that's a different deployment shape than what's committed
   today); in that case the platform's own timeout setting is what governs,
   and needs checking separately.
9. **Pointing the iOS app at it.** Set `DECIDE_API_HOST` in
   `Config/Shared.xcconfig` to the deployed hostname only (e.g.
   `api.example.com`, no scheme, no path) — `DECIDE_API_BASE_URL` assembles
   the `https://` prefix around it, and `AppConfiguration.swift` reads the
   result as `RudderAPIBaseURL`. An empty or non-HTTPS value is treated as
   "not configured" rather than crashing.
10. **Deployment-specific security checks.** Confirm: environment variables
    are only ever set through the platform's secret mechanism, never appear
    in build logs; the health-check path is the only thing reachable
    without going through steps 5–7; and step 6 is genuinely true before
    setting `DECIDE_TRUST_PROXY=1`. Error responses already never include a
    stack trace or raw exception text — `AnalysisError` messages are fixed,
    hardcoded strings — so there's nothing to configure there, just worth
    confirming after deploying (see smoke tests below).

### Deploying to Vercel specifically

`api/index.ts` adapts `handle()` to Vercel's zero-config Node.js function
convention for a bare `/api` file: `(request: IncomingMessage, response:
ServerResponse)`, not the Fetch API `Request`/`Response` signature (that
signature is for framework route handlers, e.g. Next.js App Router — a
plain `/api/*.ts` file on Vercel gets the Node-style callback instead, with
`request.headers` as a plain object). `vercel.json` rewrites every path to
this one function and sets `outputDirectory: "public"` (Vercel's "Other"
framework preset requires a static output directory even for an API-only
project; `public/index.html` is an unreachable placeholder — the rewrite
sends every real request to `/api/index` first).

Steps specific to this host, beyond the generic list above:

- **Deployment Protection.** New Vercel projects on a team enable Vercel
  Authentication (SSO) by default, which redirects every request — including
  `/healthz` — to a Vercel login page. Disable it for this project (Project
  Settings → Deployment Protection) since the endpoint's own rate limiting
  and (once configured) bearer token are the intended access control, not a
  Vercel-account login wall.
- **`DECIDE_TRUST_PROXY=1` is required here, not optional.** Vercel Functions
  have no raw socket — `remoteAddress` is always empty — so without this set,
  `resolveClientKey()` falls back to the literal string `"unknown"` for
  *every* request, and the burst/daily rate limiters end up counting all
  callers as a single shared identity instead of limiting each one
  separately. This was confirmed live: a 25-request burst against a freshly
  deployed, unconfigured instance hit the shared 429 after the 20th request
  total, from a single test client — the correct per-client behavior only
  starts once `DECIDE_TRUST_PROXY=1` is set and Vercel's edge is the only way
  to reach the function (true by construction on this platform).
- **Environment variables** are set in Project Settings → Environment
  Variables, scoped to Production — never in `vercel.json` or any committed
  file. There is no way to set them from outside Vercel's own dashboard or
  CLI; a deploy that ships without `ANTHROPIC_API_KEY` set will accept
  requests but fail every analysis call at the Anthropic SDK step.

### Smoke tests after deploying

Run in order; stop and investigate rather than continuing if one fails.
Replace `$HOST` with the deployed hostname.

```bash
# 1. Reachable over real TLS, unauthenticated, no spend.
curl -sSI "https://$HOST/healthz"
# expect: 200, and a valid certificate (no -k needed)

# 2. The security headers this build sets are actually the ones running.
curl -sSI "https://$HOST/healthz" | grep -i "strict-transport-security\|x-content-type-options\|cache-control"

# 3. Wrong route is 404, not a stack trace or a framework default page.
curl -s -o /dev/null -w "%{http_code}\n" "https://$HOST/"

# 4. If DECIDE_CLIENT_TOKEN is set: a request without it is rejected before
#    anything is spent.
curl -s -o /dev/null -w "%{http_code}\n" -X POST "https://$HOST/v1/decisions/analyze" \
  -H "Content-Type: application/json" -d '{}'
# expect: 401 (token set) or 400 (no token configured -- an empty body still
# fails schema validation, so this also confirms validation runs)

# 5. One real, deliberate, minimal-cost request -- confirms the full path
#    (Anthropic call, schema validation, citation/budget enforcement) end to
#    end. Uses complexity: simple / researchLevel: none to keep it cheap.
curl -s -X POST "https://$HOST/v1/decisions/analyze" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DECIDE_CLIENT_TOKEN" \
  -d '{
    "schemaVersion": 1, "prompt": "Coffee or tea this morning?",
    "answers": [], "knownPreferences": [], "category": "other",
    "complexity": "simple", "researchLevel": "none",
    "maximumResearchCalls": 0, "maximumSources": 0,
    "questionsAlreadyAsked": 0, "questionCeiling": 0, "locale": "en_US"
  }'
# expect: 200 and a decisionStatus in the body -- this one costs real money,
# so do it once, deliberately, not as part of a loop or a monitoring check.
```

## Known gap: who is allowed to call this

There is currently no way to verify that a request came from a genuine copy of
the app. `DECIDE_CLIENT_TOKEN` is a shared secret compiled into the app binary —
extractable by anyone who decompiles it — so it raises the cost of casual
discovery without stopping a motivated attacker. The real answer is Apple's
App Attest: the app produces a per-request assertion and the server verifies it
against the registered key. The hook is in `src/attest.ts`, and it is
deliberately binary rather than partial: `DECIDE_REQUIRE_ATTESTATION=1` refuses
*every* request (including real ones — there is no soft-pass), because a check
that pretends to run is worse than an honest gap. It has not been implemented;
turning it on is a kill switch, not a defense, until it is.

Until App Attest exists, if this endpoint's URL becomes known, anyone can call
it, gated only by the burst limit, the daily limit, the global concurrency cap,
and — if set — the bearer token. None of those establish *identity*; they only
bound the damage. Treat that as the actual security boundary this backend
offers today, and size `DECIDE_RATE_LIMIT` / `DECIDE_DAILY_LIMIT` /
`DECIDE_MAX_CONCURRENT_ANALYSES` for the worst case you can tolerate, not the
expected case — see "Cost" below for what one request can cost at the ceiling.

All three limiters (burst, daily, concurrency) are in-process. Deployed behind
more than one instance, each instance enforces its own copy, so the effective
ceiling multiplies by the instance count — either run a single instance until
that matters, or back all three with a shared store.

### Free vs. Pro: enforced here, not just in the app

This used to be entirely the app's problem: `FeatureAccess` in
`App/App/AppEnvironment.swift` capped "complex" (deep) decisions at 3/month
on-device, and this endpoint accepted whatever `complexity`/`researchLevel` a
request declared, for anyone who could reach it at all — a monetization audit
surfaced this as the real cost risk (worse than churn: nothing tied "who
pays" to "who spends AI money").

Two pieces close it, both server-side:

- **`src/appStoreVerify.ts`** independently re-verifies a StoreKit 2
  transaction's signed JWS (sent as the `X-Rudder-Transaction` header) against
  Apple's own public root of trust — never trusting a client-declared
  `isPro` boolean, the same reasoning `analyze.ts` already applies to the
  model's own JSON output. Fails closed on anything unexpected: expired,
  revoked, wrong bundle/product, malformed, or an untrusted signer all mean
  "not proven Pro," never a crash or a soft pass.
- **`src/quota.ts`** tracks complex-decision spend per install
  (`X-Rudder-Install-Id`, a random UUID the app generates once and keeps —
  see `App/Services/InstallIdentity.swift`) per calendar month, Redis-backed
  like the rate limiter, and enforces `DECIDE_FREE_DEEP_DECISIONS_PER_MONTH`
  for any request that doesn't carry a verified Pro transaction.
- **`src/spendCeiling.ts`** is the backstop the per-install quota alone
  doesn't give: an absolute ceiling (`DECIDE_MONTHLY_FREE_SPEND_CEILING_USD`,
  default $12) on *total* estimated Free-tier spend across every install,
  every month. Enough simultaneous installs each spending their own small
  quota can still add up past what the business can absorb before
  conversion catches up — this is what makes the worst case a fixed, known
  number instead of "however many people show up this month." It trips
  independently of the per-install quota, applies to every complexity (not
  just "complex"), and never applies to a verified Pro transaction.

**What this does not (yet) solve:** identity itself. `appStoreVerify.ts` has
only ever been exercised against a synthetic certificate chain built for its
own unit tests (`src/test/appStoreVerify.test.ts`) — there is no Xcode/macOS
or real Apple transaction available in the environment this was written in,
so it has never been proven against an actual StoreKit purchase end to end.
Treat that the same as the App Attest gap above: confirm it during the
Product Reality Test, with one real purchase, before trusting it in
production. If it's ever silently broken, the fail-closed design means the
failure mode is a paying user held to the Free quota (visible, recoverable),
never the server granting free unmetered access.

## Cost

Effort is the cost lever, not a cheaper model: one model means one prompt cache
and one set of API semantics, and low effort on the current model buys more
quality per unit of spend than a downgrade. The map lives in `src/budget.ts`:

| Complexity | Effort | Searches | Max tokens |
|---|---|---|---|
| simple | low | 0 | 8,000 |
| medium | medium | up to 2 | 8,000 |
| complex | high | up to 6 | 16,000 |

The system prompt is cached, so the per-request cost is dominated by the decision
itself rather than by the instructions.

## The contract

`src/schema.ts` mirrors `AIDecisionResponse` in
`Packages/RudderKit/Sources/RudderCore/AI/AIContract.swift`. They are kept honest
by a test on each side: the backend's contract test writes a real response to
`Packages/RudderKit/Tests/RudderCoreTests/Fixtures/backend_contract.json`, and
the Swift suite decodes and validates that same file. Break either side and both
suites fail.
