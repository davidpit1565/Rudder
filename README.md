# RUDDER

A decision intelligence app for iPhone. You say what you're deciding; RUDDER
works out what it turns on, looks up what it can, asks only what it genuinely
cannot know, and gives you a recommendation with the trade-off, how stable it is,
and the strongest case against it.

**AI does the work. You make the decision.**

## Layout

```
Rudder.xcodeproj          The iPhone app (Xcode 16+, iOS 17+)
project.yml               XcodeGen spec — regenerates the project if needed

App/                      SwiftUI, SwiftData, StoreKit
  Features/               Home, NewDecision, Recommendation, DecisionDetails,
                          Decisions, Profile, Paywall
  Services/               Persistence, subscriptions
  Shared/                 Design system and components

Packages/RudderKit/       Everything that does not need UIKit
  Sources/RudderCore/     Domain, decision/stability/question/memory engines,
                          the AI contract and its validator
  Sources/RudderFlow/     The decision pipeline: coordinator, service, config
  Tests/                  135 tests

Tests/RudderAppTests/     Persistence, entitlements, presentation
Tests/RudderUITests/      XCUITests against the running app

Backend/                  The analysis endpoint (TypeScript). Holds the model
                          credential so the app never does.

Config/                   Info.plist, xcconfigs, StoreKit configuration
AppStore/                 Metadata, privacy answers, screenshots, review notes
```

## Why it is split this way

The whole of RUDDER's reasoning lives in `RudderKit`, which depends on nothing
but Foundation. That means the engines, the state machine, the AI response
validator and the decision pipeline can be built and tested on any machine —
including CI without Xcode — and that the app target on top of them is only
presentation, persistence and StoreKit.

```bash
cd Packages/RudderKit && swift test     # 135 tests, no simulator needed
cd Backend && npm test                  # 29 tests, no network, no spend
```

In Xcode: **Product ▸ Test** runs those plus the app-layer and UI tests.

## Before shipping

Everything that needs an account you must own is listed in
[`AppStore/RELEASE.md`](AppStore/RELEASE.md).
