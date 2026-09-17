// swift-tools-version: 6.2
// Slightshot — an open-source, native macOS successor to Lightshot.

import PackageDescription

let package = Package(
    name: "Slightshot",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Slightshot", targets: ["Slightshot"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Slightshot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Slightshot",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by Scripts/bundle.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
