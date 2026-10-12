# Release checklist

Everything the code can settle is settled. What remains needs App Store
Connect itself, or a decision only the account owner can make — not another
line of code.

## Done

- **Apple Developer account and Team ID** — set in Xcode (David Pitchkhadze).
- **Bundle identifier** — `com.davidpitchkhadze.rudder`, live everywhere in
  the codebase (app, widget, App Group, subscription product IDs, backend).
  Still needs confirming it's registered in the Apple Developer portal with
  **In-App Purchase** and **App Groups** enabled, and selectable in the App
  Store Connect app record.
- **Backend deployment** — live at `decide-mu-navy.vercel.app`, verified
  working end-to-end against a real request (not just `/healthz`).
- **Privacy policy, terms and support pages** — published and wired up in
  `Config/Release.xcconfig`, contact address set to `davidpit2008@gmail.com`
  (a real inbox, used as a stopgap — swap it for something more permanent
  whenever that exists).
- **Three production bugs found while verifying all of the above end to
  end** — the serverless function had no `maxDuration`, so a real decision
  could be killed mid-request; the free-tier quota rejected even the first
  (meant to be unconditionally free) deep decision at the shipped limit of 0;
  and a "complex" decision's two sequential model calls (research, then
  analysis) could still blow past the 60s ceiling at the original budget —
  trimmed down. All three fixed and confirmed live. A real content bug was
  also found and fixed: the trade-off sentence ("You're giving up X to get
  Y.") could read "...X. to get Y.." when the model's own
  `gaining`/`givingUp` text already carried a trailing period.
- **Switched AI provider, from Anthropic to Google's Gemini API** — the
  Anthropic account backing production ran out of its prepaid credit balance
  mid-launch, silently failing every decision (not just complex ones) with
  no warning. Gemini has no equivalent failure mode: its free tier is
  genuinely free (rate-limited, not billed), and its paid tier is real
  pay-as-you-go against a linked card rather than a balance to manually top
  up. `Backend/src/budget.ts` now runs `gemini-3.5-flash-lite` (simple,
  medium) and `gemini-3.8-flash` (complex); see `Backend/README.md`'s "Cost"
  section. **Needs you:** decide free vs. paid tier for the production
  `GEMINI_API_KEY` before launch — see item 6 below, it changes what the
  privacy policy has to say.

## Needs you

1. **Subscription products** — create the two products from
   `AppStore/subscriptions.md` with exactly those identifiers, in one group,
   with the 7-day free trial and prices set per territory. (In progress.)

2. **Keep the listing's numbers honest**
   `FeatureAccess.freeDeepDecisionsPerMonth` and `FeatureAccess.freeHistoryLimit`
   in `App/App/AppEnvironment.swift` are the single source of truth, and every
   in-app string interpolates them. The App Store description in
   `AppStore/metadata.md` spells them out in words, so if either constant ever
   changes, change that sentence too.

3. **App Store listing** — `AppStore/metadata.md` has the name, subtitle,
   description, keywords and category (name needs picking fresh — "Rudder"
   alone is already taken). `AppStore/screenshots.md` has the seven shots and
   what must be in each; `AppStore/review-notes.md` is the reviewer note.

4. **App Privacy answers** — `AppStore/privacy.md` has the exact answers,
   including the third-party AI provider declaration; they just need typing
   into App Store Connect's own questionnaire.

5. **App Attest (deliberately deferred, not a launch blocker)**
   The endpoint is currently protected by a burst rate limit, a daily limit
   and a global concurrency cap — none of which establish identity, only
   bound the damage. The $5/month absolute spend ceiling already bounds the
   actual financial risk regardless. `Backend/src/attest.ts` is the hook for
   implementing this properly later; see the "Known gap" section in
   `Backend/README.md`.

6. **Set `GEMINI_API_KEY` in Vercel and pick a tier** — the old
   `ANTHROPIC_API_KEY` is gone from the code; production needs a real
   `GEMINI_API_KEY` (Project Settings → Environment Variables) before any
   decision will work. Get one at
   [aistudio.google.com/apikey](https://aistudio.google.com/apikey).
   Two real choices, not just a formality:
   - **Free tier** (no billing account attached) — genuinely $0, but
     Google's own terms permit it to use the decision text you send to
     improve its products, with human reviewers able to read it.
     `Backend/public/privacy.html` and `AppStore/privacy.md` are already
     written to disclose this honestly for this tier.
   - **Paid tier** (a Cloud Billing account with a card attached, no plan
     change needed otherwise) — real pay-as-you-go, a few cents per 1,000
     decisions at these models' prices, and Google does not use the content
     to improve its products. If you switch, update both privacy documents
     to drop the free-tier training disclosure before submitting.
   Given Rudder analyses people's personal decisions, the paid tier is the
   safer default the moment it's convenient to set up — but the free tier is
   enough to get the app working and tested right now.

## Before you archive

- [ ] `cd Packages/RudderKit && swift test` — confirm all pass
- [ ] `cd Backend && npm test` — 85 tests, all pass
- [ ] Product ▸ Test in Xcode — app-layer and UI tests on a simulator
- [ ] Run once on a small device (iPhone SE) and a large one, in both appearances
- [ ] Settings ▸ Accessibility ▸ Larger Text at the largest size: no clipped
      buttons, no truncated recommendations
- [ ] VoiceOver through Home → question → recommendation → choice
- [ ] Airplane mode: a new decision explains itself; saved decisions still open
- [ ] Buy, cancel and restore against `Config/Rudder.storekit`
- [ ] Force-quit after saving a decision; reopen and confirm it is still there
- [ ] Archive with the Release configuration and check Xcode's privacy report
- [ ] Confirm the archived build points at the production API host

## Version numbers

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in
`Config/Shared.xcconfig`. Bump the build number for every upload.
