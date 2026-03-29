// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FXDesign",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FXDesign", targets: ["FXDesign"]),
    ],
    targets: [
        .target(name: "FXDesign"),
    ]
)
