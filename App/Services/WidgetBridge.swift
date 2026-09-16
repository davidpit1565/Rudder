import Foundation
import RudderFlow

/// Hands the latest decision to the widget extension across the process
/// boundary via a small JSON file in the shared App Group container -- not the
/// full SwiftData store, which the widget has no business opening directly.
///
/// Compiled into both the app target and the widget extension target (see
/// project.yml), since `containerURL(forSecurityApplicationGroupIdentifier:)`
/// is a Darwin-only Foundation API and so cannot live in RudderKit, which also
/// has to build on Linux CI.
enum WidgetBridge {
    static let appGroupIdentifier = "group.com.rudder.app"
    private static let fileName = "widget_snapshot.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    /// Called from the app after every reload. Silently does nothing if the App
    /// Group isn't available (e.g. the entitlement isn't provisioned yet) -- a
    /// missing widget snapshot is a widget showing its empty state, never a crash.
    static func write(_ snapshot: WidgetSnapshot?) {
        guard let fileURL else { return }
        guard let snapshot else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Called from the widget extension's timeline provider.
    static func read() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
