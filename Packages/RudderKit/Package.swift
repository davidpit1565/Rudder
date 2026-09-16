// swift-tools-version: 6.0
import PackageDescription

/// RudderKit holds everything in the product that does not need UIKit or SwiftUI:
///
///   RudderCore  the decision, stability, question and memory engines
///   RudderFlow  the decision pipeline: coordinator, service contract, configuration
///
/// Keeping these out of the app target means the whole of RUDDER's reasoning can be
/// built and tested on any machine, including CI without Xcode. The app target on
/// top of it is presentation, persistence and StoreKit.
let package = Package(
    name: "RudderKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RudderCore", targets: ["RudderCore"]),
        .library(name: "RudderFlow", targets: ["RudderFlow"])
    ],
    targets: [
        .target(
            name: "RudderCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RudderCoreTests",
            dependencies: ["RudderCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RudderFlow",
            dependencies: ["RudderCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RudderFlowTests",
            dependencies: ["RudderFlow", "RudderCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
