// swift-tools-version: 6.0
import PackageDescription

// SheepJumphost — SheepTerm's ProxyJump: run one SSH session through a
// direct-tcpip channel of another (the bastion). Sans-I/O like SheepSSH: the
// app's SSHLink owns the sockets and the poll loop; this package owns the
// adapter between the bastion connection's channel and the inner transport,
// the hop description, and the tests that pin the routing rules.
let package = Package(
    name: "SheepJumphost",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SheepJumphost", targets: ["SheepJumphost"]),
    ],
    dependencies: [
        .package(path: "../SheepSSH"),
    ],
    targets: [
        .target(
            name: "SheepJumphost",
            dependencies: [.product(name: "SheepSSH", package: "SheepSSH")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheepJumphostTests",
            dependencies: ["SheepJumphost", .product(name: "SheepSSH", package: "SheepSSH")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
