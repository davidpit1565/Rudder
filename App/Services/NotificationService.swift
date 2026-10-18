import Foundation
import UserNotifications

/// Local, on-device reminders only -- no APNs, no device-token registration,
/// no server round-trip. A real server-pushed notification would need an
/// Apple Push Notification key from the developer's own account plus new
/// backend infrastructure to store device tokens; this covers the
/// re-engagement case without any of that.
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let reengagementIdentifier = "rudder.reengagement"

    /// How long the app has to be in the background before the reminder
    /// fires. Rescheduled every time the app backgrounds, and cancelled
    /// outright the moment it's reopened, so it only ever fires after a
    /// real multi-day absence -- never while the user is actively using it.
    private let reengagementDelay: TimeInterval = 3 * 24 * 60 * 60

    private init() {}

    /// Asks only when there's something to ask for, never on first launch:
    /// call this once, right after the user's first completed decision, so
    /// the permission prompt follows real value rather than preceding it.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Call when the app moves to the background.
    func scheduleReengagementReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Still thinking something through?"
        content.body = "RUDDER's ready whenever you are."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: reengagementDelay, repeats: false)
        let request = UNNotificationRequest(identifier: reengagementIdentifier, content: content, trigger: trigger)
        center.add(request)
    }

    /// Call when the app becomes active, so a reminder never fires while --
    /// or right after -- the user is already back in the app.
    func cancelReengagementReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [reengagementIdentifier])
    }
}
