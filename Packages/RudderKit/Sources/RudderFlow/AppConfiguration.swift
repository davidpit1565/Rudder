import Foundation

/// Everything environment-specific, read from the bundle at launch.
///
/// There is deliberately no API key here: the app talks only to RUDDER's own
/// endpoint, which holds the provider credentials server-side.
/// Anything that can answer "what is configured under this key?".
/// Lets the configuration be tested without building a bundle.
public protocol InfoValueProviding {
    func infoValue(forKey key: String) -> String?
}

extension Bundle: InfoValueProviding {
    public func infoValue(forKey key: String) -> String? {
        object(forInfoDictionaryKey: key) as? String
    }
}

public struct AppConfiguration: Sendable {
    public let apiBaseURL: URL?
    public let privacyPolicyURL: URL?
    public let termsURL: URL?
    public let supportURL: URL?

    public static let shared = AppConfiguration(bundle: .main)

    public init(bundle: Bundle) {
        self.init(info: bundle)
    }

    public init(info: InfoValueProviding) {
        func url(_ key: String) -> URL? {
            // "https://" with nothing after it parses as a URL and reports an
            // empty host, so a host has to be required explicitly — otherwise an
            // unconfigured build looks configured.
            guard let value = info.infoValue(forKey: key)?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty,
                  let url = URL(string: value),
                  url.scheme?.lowercased() == "https",
                  let host = url.host(), !host.isEmpty
            else { return nil }
            return url
        }

        apiBaseURL = url("RudderAPIBaseURL")
        privacyPolicyURL = url("RudderPrivacyPolicyURL")
        termsURL = url("RudderTermsURL")
        supportURL = url("RudderSupportURL")
    }

    /// True when the app has somewhere to send analysis requests.
    public var isBackendConfigured: Bool { apiBaseURL != nil }
}
