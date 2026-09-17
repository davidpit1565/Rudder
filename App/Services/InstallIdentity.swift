import Foundation

/// A stable, anonymous identifier for this install -- no account, no device
/// fingerprinting, just a random UUID generated once and kept in
/// `UserDefaults`. RUDDER's backend uses it to enforce the Free tier's
/// monthly deep-decision cap per install rather than trusting whatever a
/// request claims about itself (see the "Known gap" section of
/// `Backend/README.md`, and `Backend/src/quota.ts`).
enum InstallIdentity {
    private static let key = "com.rudder.app.installId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}
