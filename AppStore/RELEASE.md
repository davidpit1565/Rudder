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
  `Config/Release.xcconfig`. One placeholder remains: the contact address in
  all three pages is still `support@rudder.app`, not a real monitored inbox.
- **The two production bugs found while verifying the above** — the
  serverless function had no `maxDuration`, so any real decision could be
  killed mid-request before finishing; and the free-tier quota rejected even
  the first (meant to be unconditionally free) deep decision at the shipped
  limit of 0. Both fixed and confirmed live.

## Needs you

1. **Subscription products** — create the two products from
   `AppStore/subscriptions.md` with exactly those identifiers, in one group,
   with the 7-day free trial and prices set per territory. (In progress.)

2. **A real support email** — replace `support@rudder.app` in
   `Backend/public/privacy.html`, `terms.html` and `support.html` with an
   address you actually control and will check. Tell me the address and I'll
   make the edit — I can't invent one for you.

3. **Keep the listing's numbers honest**
   `FeatureAccess.freeDeepDecisionsPerMonth` and `FeatureAccess.freeHistoryLimit`
   in `App/App/AppEnvironment.swift` are the single source of truth, and every
   in-app string interpolates them. The App Store description in
   `AppStore/metadata.md` spells them out in words, so if either constant ever
   changes, change that sentence too.

4. **App Store listing** — `AppStore/metadata.md` has the name, subtitle,
   description, keywords and category (name needs picking fresh — "Rudder"
   alone is already taken). `AppStore/screenshots.md` has the seven shots and
   what must be in each; `AppStore/review-notes.md` is the reviewer note.

5. **App Privacy answers** — `AppStore/privacy.md` has the exact answers,
   including the third-party AI provider declaration; they just need typing
   into App Store Connect's own questionnaire.

6. **App Attest (deliberately deferred, not a launch blocker)**
   The endpoint is currently protected by a burst rate limit, a daily limit
   and a global concurrency cap — none of which establish identity, only
   bound the damage. The $5/month absolute spend ceiling already bounds the
   actual financial risk regardless. `Backend/src/attest.ts` is the hook for
   implementing this properly later; see the "Known gap" section in
   `Backend/README.md`.

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
