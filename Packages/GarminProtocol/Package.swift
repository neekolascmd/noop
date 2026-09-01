// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GarminProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "GarminProtocol", targets: ["GarminProtocol"])],
    targets: [
        .target(name: "GarminProtocol"),
        .testTarget(name: "GarminProtocolTests", dependencies: ["GarminProtocol"]),
    ]
)
