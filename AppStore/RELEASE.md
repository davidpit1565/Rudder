# Release checklist

Everything the code can settle is settled. What remains needs an account or a
domain that only the account owner can provide.

## Needs you

1. **Apple Developer account and Team ID**
   Set the team in Xcode (Signing & Capabilities). Signing is `Automatic`; no
   provisioning profiles are committed.

2. **Bundle identifier**
   `com.rudder.app` is the placeholder in `Config/Shared.xcconfig`. Change it to
   one your team owns, in that one file, and register it in App Store Connect
   with **In-App Purchase** enabled.

3. **Backend deployment**
   Deploy `Backend/` somewhere with TLS and set `ANTHROPIC_API_KEY` in its
   environment. Then set `RUDDER_API_HOST` in `Config/Shared.xcconfig` to its
   hostname — it ships empty. Until it is set, and for any value that is not
   HTTPS, the app says "RUDDER isn't connected yet" rather than failing against a
   host that does not exist.

4. **Privacy policy, terms and support pages**
   Publish all three, then set `RUDDER_PRIVACY_POLICY_HOST`, `RUDDER_TERMS_HOST`
   and `RUDDER_SUPPORT_HOST` in `Config/Shared.xcconfig`. `AppStore/privacy.md`
   lists what the policy has to cover. They ship empty, and the app hides a link
   it has no URL for rather than showing a dead one — but App Store Connect will
   not accept a submission without a privacy policy URL.

5. **Subscription products**
   Create the two products from `AppStore/subscriptions.md` with exactly those
   identifiers, in one group, and set prices per territory.

6. **Keep the listing's numbers honest**
   `FeatureAccess.freeDeepDecisionsPerMonth` and `FeatureAccess.freeHistoryLimit`
   in `App/App/AppEnvironment.swift` are the single source of truth, and every
   in-app string interpolates them. The App Store description in
   `AppStore/metadata.md` spells them out in words ("three… ten"), so if you
   change either constant, change that sentence too — a listing that overstates
   the free tier is a rejection risk as well as untrue.

7. **App Store listing**
   `AppStore/metadata.md` has the name, subtitle, description, keywords and
   category. `AppStore/screenshots.md` has the seven shots and what must be in
   each. `AppStore/review-notes.md` is the reviewer note.

8. **App Privacy answers**
   `AppStore/privacy.md` has the exact answers, including the third-party AI
   provider declaration.

9. **App Attest (recommended before any real traffic)**
   The endpoint is currently protected by a burst rate limit, a daily limit and
   a global concurrency cap — none of which establish identity, only bound the
   damage. `Backend/src/attest.ts` is the hook; until it is implemented, anyone
   who finds the URL can still spend your model budget, just within those
   ceilings. See the "Known gap" section in `Backend/README.md`, and size
   `DECIDE_RATE_LIMIT` / `DECIDE_DAILY_LIMIT` / `DECIDE_MAX_CONCURRENT_ANALYSES`
   (in `Backend/.env.example`) for the worst case before going live.

## Before you archive

- [ ] `cd Packages/RudderKit && swift test` — 142 tests
- [ ] `cd Backend && npm test` — 54 tests
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
