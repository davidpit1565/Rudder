import AppIntents
import RudderFlow

/// "Hey Siri, ask Rudder what to decide" -- hands the spoken or typed prompt
/// straight to the home screen instead of making the user retype it once the
/// app is open. `PendingSiriDecision` (RudderFlow, unit tested) is the only
/// thing this intent touches: it cannot reach into the view hierarchy directly
/// since it runs out-of-process from SwiftUI.
struct StartDecisionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Decision"
    static var description = IntentDescription(
        "Tells Rudder what you're deciding so it can start researching right away."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "What are you deciding?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingSiriDecision.shared.set(prompt)
        return .result()
    }
}

struct RudderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDecisionIntent(),
            phrases: [
                // Embeds the parameter so a single utterance -- "Ask Rudder should I
                // take this job" -- fills `prompt` directly from speech. Without it,
                // App Intents falls back to asking "What are you deciding?" after the
                // app opens, which still works but costs an extra step.
                "Ask \(.applicationName) \(\.$prompt)",
                "Start a decision with \(.applicationName)"
            ],
            shortTitle: "Start a Decision",
            systemImageName: "arrow.triangle.branch"
        )
    }
}
