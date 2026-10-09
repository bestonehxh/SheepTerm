// swift-tools-version: 6.0
import PackageDescription

// SheepSync — Termius-style sync for the Sheep apps: sign in with Google, and
// the app's records (configuration AND secrets) follow the user to every Mac,
// end-to-end encrypted with a key only the user's passphrase can unwrap.
//
// Nothing in here knows about SheepTerm. An app adopts it by giving a
// `SyncConfiguration` (names, Google client, Keychain service) and a
// `SyncDataSource` (records out, records in) — see SPEC.md. Storage is the
// user's OWN Google Drive (`appDataFolder`), so there is no server of ours.
// Crypto is Apple's only: CryptoKit (AES-GCM, HMAC, SHA-256) and CommonCrypto
// (PBKDF2).
let package = Package(
    name: "SheepSync",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SheepSync", targets: ["SheepSync"]),
    ],
    targets: [
        .target(
            name: "SheepSync",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepSyncTests",
            dependencies: ["SheepSync"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
