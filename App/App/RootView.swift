import SwiftUI
import Foundation

/// Two places, and no more: make a decision (and see every past one on the
/// same screen), and manage what RUDDER knows about you.
struct RootView: View {
    enum Tab: Hashable {
        case decide
        case profile
    }

    var startupError: String?

    @State private var selection: Tab = .decide
    @State private var showingStartupError = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    /// UI tests run on a fresh simulator every time, so `hasSeenOnboarding`
    /// starts false there exactly as it would for a real new user -- without
    /// this, every existing UI test that expects to land on Home immediately
    /// would instead land on the onboarding flow. Tests exercise actual
    /// features, not the one-time first-launch screen, so a test scenario
    /// skips it the same way it already skips other first-run states.
    private var shouldShowOnboarding: Bool {
        #if DEBUG
        if UITestHarness.isActive { return false }
        #endif
        return !hasSeenOnboarding
    }

    var body: some View {
        Group {
            if !shouldShowOnboarding {
                TabView(selection: $selection) {
                    HomeView()
                        .tabItem { Label("Decide", systemImage: "arrow.triangle.branch") }
                        .tag(Tab.decide)

                    ProfileView()
                        .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                        .tag(Tab.profile)
                }
                .onAppear { showingStartupError = startupError != nil }
                .alert("Storage problem", isPresented: $showingStartupError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(startupError ?? "")
                }
            } else {
                OnboardingView(onFinish: { hasSeenOnboarding = true })
            }
        }
        // A reminder is scheduled on every backgrounding and cancelled on
        // every foregrounding, so it only ever reaches the user after a real
        // multi-day absence -- never while, or right after, they're already
        // back in the app.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                NotificationService.shared.scheduleReengagementReminder()
            case .active:
                NotificationService.shared.cancelReengagementReminder()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
