import WidgetKit
import SwiftUI
import RudderFlow

struct RudderWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct RudderWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RudderWidgetEntry {
        RudderWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                title: "Which laptop should I buy?",
                subtitle: "MacBook Air",
                strengthTitle: "Strong",
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RudderWidgetEntry) -> Void) {
        completion(RudderWidgetEntry(date: Date(), snapshot: WidgetBridge.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RudderWidgetEntry>) -> Void) {
        let entry = RudderWidgetEntry(date: Date(), snapshot: WidgetBridge.read())
        // The widget only ever changes when the app writes a new snapshot and asks
        // WidgetKit to reload -- nothing here is time-based, so a single entry that
        // never expires on its own is correct, not a placeholder left unfinished.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct RudderWidgetView: View {
    var entry: RudderWidgetProvider.Entry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(snapshot.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(snapshot.strengthTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                Text("Start a decision")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RudderWidget: Widget {
    let kind = "RudderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RudderWidgetProvider()) { entry in
            RudderWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Latest Decision")
        .description("Shows your most recent decision and its recommendation.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct RudderWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        RudderWidget()
    }
}
