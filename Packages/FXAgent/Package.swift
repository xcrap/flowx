// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FXAgent",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FXAgent", targets: ["FXAgent"]),
    ],
    dependencies: [
        .package(path: "../FXCore"),
    ],
    targets: [
        .target(name: "FXAgent", dependencies: ["FXCore"]),
    ]
)
