import SwiftUI
import Foundation

@main
struct RudderApp: App {
    @State private var environment: AppEnvironment

    init() {
        // Storage that cannot be opened must never take the app down. `best()`
        // falls back from disk to memory to nothing, and the mode is surfaced to
        // the user rather than swallowed.
        let persistence = PersistenceService.best()

        #if DEBUG
        // The UI suite runs against the real on-disk store — that is the point of
        // the persistence test — and clears it only when it asks to start clean.
        if UITestHarness.shouldResetStore {
            try? persistence.deleteEverything()
        }
        #endif

        _environment = State(initialValue: AppEnvironment(persistence: persistence))
    }

    var body: some Scene {
        WindowGroup {
            RootView(startupError: environment.storageWarning)
                .environment(environment)
                .tint(RudderColor.accent)
                .task {
                    await environment.subscriptions.refreshEntitlement()
                    await environment.subscriptions.loadProducts()
                    environment.refreshMemoryCandidate()
                }
        }
    }
}
