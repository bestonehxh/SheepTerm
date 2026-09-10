// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SheepVT",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SheepVT", targets: ["SheepVT"]),
        .library(name: "SheepVTRender", targets: ["SheepVTRender"]),
    ],
    targets: [
        // The core: parser, grid, terminal state, selection, search, encoders. No AppKit.
        .target(
            name: "SheepVT",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The macOS half: NSView + CAMetalLayer renderer, overlays, pty. Main-actor by default,
        // like the app.
        .target(
            name: "SheepVTRender",
            dependencies: ["SheepVT"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Dev-only: `swift run SheepVTDemo` opens a window with a TerminalView on a local shell.
        .executableTarget(
            name: "SheepVTDemo",
            dependencies: ["SheepVTRender"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "SheepVTTests",
            dependencies: ["SheepVT"],
            resources: [.copy("../Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepVTRenderTests",
            dependencies: ["SheepVTRender", "SheepVT"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
