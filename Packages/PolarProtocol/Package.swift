// swift-tools-version: 5.9
import PackageDescription

// Clean-room Polar Measurement Data (PMD) wire implementation. The target is deliberately
// platform-pure: no CoreBluetooth and no Polar SDK dependency, so packets can be tested and
// replayed on any SwiftPM host while the apps own transport and persistence.
let package = Package(
    name: "PolarProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PolarProtocol", targets: ["PolarProtocol"]),
    ],
    targets: [
        .target(name: "PolarProtocol"),
        .testTarget(name: "PolarProtocolTests", dependencies: ["PolarProtocol"]),
    ]
)
