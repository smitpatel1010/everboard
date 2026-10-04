// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Everboard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Everboard", targets: ["EverboardMac"]),
        .executable(name: "everboard-cli", targets: ["everboard-cli"]),
        .library(name: "EverboardCore", targets: ["EverboardCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "EverboardCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EverboardMac",
            dependencies: ["EverboardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "everboard-cli",
            dependencies: ["EverboardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EverboardCoreTests",
            dependencies: ["EverboardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
