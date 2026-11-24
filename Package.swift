// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TypstKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        .library(
            name: "TypstUniverseKit",
            targets: ["TypstUniverseCore", "TypstUniverseStorage", "TypstUniverseUI"]
        ),
        .library(name: "AnyTyp", targets: ["AnyTyp"]),
    ],
    dependencies: [
        // Build-time only: powers `swift package generate-documentation`.
        // Never linked into library products.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "TypstUniverseCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "TypstUniverseStorage",
            dependencies: ["TypstUniverseCore"]
        ),
        .target(
            name: "TypstUniverseUI",
            dependencies: ["TypstUniverseCore", "TypstUniverseStorage"],
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "AnyTyp",
            dependencies: ["CZlib"],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "AnyTypCLI",
            dependencies: ["AnyTyp"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TypstUniverseCoreTests",
            dependencies: ["TypstUniverseCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TypstUniverseStorageTests",
            dependencies: ["TypstUniverseCore", "TypstUniverseStorage"]
        ),
        .testTarget(
            name: "TypstUniverseUITests",
            dependencies: ["TypstUniverseCore", "TypstUniverseStorage", "TypstUniverseUI"]
        ),
        .testTarget(
            name: "AnyTypTests",
            dependencies: ["AnyTyp"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
