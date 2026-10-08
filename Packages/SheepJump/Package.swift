// swift-tools-version: 6.0
import PackageDescription

// SheepJump — SheepTerm's ProxyJump: run one SSH session through a
// direct-tcpip channel of another (the bastion). Sans-I/O like SheepSSH: the
// app's SSHLink owns the sockets and the poll loop; this package owns the
// adapter between the bastion connection's channel and the inner transport,
// the hop description, and the tests that pin the routing rules.
let package = Package(
    name: "SheepJump",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SheepJump", targets: ["SheepJump"]),
    ],
    dependencies: [
        .package(path: "../SheepSSH"),
    ],
    targets: [
        .target(
            name: "SheepJump",
            dependencies: [.product(name: "SheepSSH", package: "SheepSSH")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepJumpTests",
            dependencies: ["SheepJump", .product(name: "SheepSSH", package: "SheepSSH")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
