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
// Windows (the SheepTerm Windows port in ../SheepTerm-Windows) compiles the same
// sources: `Crypto` from swift-crypto stands in for CryptoKit, FoundationNetworking
// for URLSession, and the few Apple-only pieces (Keychain, Network.framework,
// PBKDF2 from CommonCrypto) sit behind `#if` seams. macOS is unchanged.
#if os(Windows) || os(Linux)
let portableDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
let portableTargetDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let portableDependencies: [Package.Dependency] = []
let portableTargetDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "SheepSync",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SheepSync", targets: ["SheepSync"]),
    ],
    dependencies: portableDependencies,
    targets: [
        .target(
            name: "SheepSync",
            dependencies: portableTargetDependencies,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepSyncTests",
            dependencies: ["SheepSync"] + portableTargetDependencies,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
