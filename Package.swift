// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RTFMLicensing",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RTFMLicensing", targets: ["RTFMLicensing"]),
    ],
    targets: [
        .target(name: "RTFMLicensing"),
        // A command-line sample: `swift run rtfm-license-sample <app-integration.json> status`.
        .executableTarget(name: "rtfm-license-sample", dependencies: ["RTFMLicensing"], path: "Examples/LicenseSample"),
        .testTarget(name: "RTFMLicensingTests", dependencies: ["RTFMLicensing"], resources: [.copy("Fixtures")]),
    ]
)
