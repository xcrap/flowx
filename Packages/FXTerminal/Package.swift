// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FXTerminal",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FXTerminal", targets: ["FXTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.12.0"),
    ],
    targets: [
        .target(
            name: "FXTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)
