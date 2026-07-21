// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TelexCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TelexCore", targets: ["TelexCore"]),
        .executable(name: "gen-lessons", targets: ["GenLessons"]),
        .executable(name: "gen-english", targets: ["GenEnglish"])
    ],
    targets: [
        .target(
            name: "TelexCore",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "GenLessons",
            dependencies: ["TelexCore"]
        ),
        .executableTarget(
            name: "GenEnglish",
            dependencies: ["TelexCore"]
        ),
        .testTarget(
            name: "TelexCoreTests",
            dependencies: ["TelexCore"]
        )
    ]
)
