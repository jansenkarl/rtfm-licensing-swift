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
        .testTarget(name: "RTFMLicensingTests", dependencies: ["RTFMLicensing"]),
    ]
)
