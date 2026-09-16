import SwiftUI
import Foundation

/// Three places, and no more: make a decision, look at past ones, manage what
/// RUDDER knows about you.
struct RootView: View {
    enum Tab: Hashable {
        case decide
        case decisions
        case profile
    }

    var startupError: String?

    @State private var selection: Tab = .decide
    @State private var showingStartupError = false

    var body: some View {
        TabView(selection: $selection) {
            HomeView(onSeeAllDecisions: { selection = .decisions })
                .tabItem { Label("Decide", systemImage: "arrow.triangle.branch") }
                .tag(Tab.decide)

            DecisionsView()
                .tabItem { Label("Decisions", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.decisions)

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
    }
}
