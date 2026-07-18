// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TelexCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TelexCore", targets: ["TelexCore"])
    ],
    targets: [
        .target(
            name: "TelexCore",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "TelexCoreTests",
            dependencies: ["TelexCore"]
        )
    ]
)
