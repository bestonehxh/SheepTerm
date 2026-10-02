// swift-tools-version: 6.0
import PackageDescription

// SheepSSH — SheepTerm's own SSH client, replacing libssh + OpenSSL.
//
// On macOS the only crypto underneath is Apple's (CryptoKit, CommonCrypto,
// Security); everything those do not provide is written here and pinned by
// test vectors. On Linux — used only to run the test suite in CI-like
// containers — `Crypto` from swift-crypto stands in for CryptoKit with the
// same API. It is never linked into the app.
#if os(Linux)
let linuxDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
let linuxTargetDependencies: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "_CryptoExtras", package: "swift-crypto"),
]
#else
let linuxDependencies: [Package.Dependency] = []
let linuxTargetDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "SheepSSH",
    // macOS 26+ like the app (deployment target 26.4); CryptoKit's ML-KEM
    // needs it.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SheepSSH", targets: ["SheepSSH"]),
    ],
    dependencies: linuxDependencies,
    targets: [
        .target(
            name: "SheepSSH",
            dependencies: linuxTargetDependencies,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepSSHTests",
            dependencies: ["SheepSSH"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
