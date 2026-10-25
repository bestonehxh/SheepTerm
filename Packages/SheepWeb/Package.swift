// swift-tools-version: 6.0
import PackageDescription

// SheepWeb — the web engine pieces SheepTerm's web tabs and the other Sheep apps share (5.0 (53)):
// the error page, the login-field rules (page script + fill), page-drawn site icons,
// address-bar suggestions (Google, never for a private address) and the drop-down list.
// One copy: a fix here reaches both apps on their next build. UI that differs (the bar,
// tabs, the key vs. the list) stays in each app. Contract: README.md.
let package = Package(
    name: "SheepWeb",
    defaultLocalization: "en",
    platforms: [.macOS("26.4")],
    products: [
        .library(name: "SheepWeb", targets: ["SheepWeb"]),
        // Foundation only (the login-field scripts): SheepTerm's shared core — compiled on
        // Windows too — names this target from the repo's root Package.swift.
        .library(name: "SheepWebScripts", targets: ["SheepWebScripts"]),
    ],
    targets: [
        .target(
            name: "SheepWebScripts",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SheepWeb",
            dependencies: ["SheepWebScripts"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepWebTests",
            dependencies: ["SheepWeb", "SheepWebScripts"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
