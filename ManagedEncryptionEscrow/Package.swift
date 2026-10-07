// swift-tools-version:6.0
import PackageDescription

// Managed Encryption Escrow: the Prefs / Run / Logs window for Crypt. It ships in
// the Crypt package; checkin, the login plugin and their launchd job are
// unchanged, and the GUI talks to the engine only through the root helper.
let package = Package(
    name: "ManagedEncryptionEscrow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ManagedEncryptionEscrowApp", targets: ["ManagedEncryptionEscrowApp"]),
        .executable(name: "ManagedEncryptionEscrowHelper", targets: ["ManagedEncryptionEscrowHelper"])
    ],
    targets: [
        .target(
            name: "ManagedEncryptionEscrowXPC",
            path: "Sources/ManagedEncryptionEscrowXPC"
        ),
        .executableTarget(
            name: "ManagedEncryptionEscrowApp",
            dependencies: ["ManagedEncryptionEscrowXPC"],
            path: "Sources/ManagedEncryptionEscrowApp"
        ),
        .executableTarget(
            name: "ManagedEncryptionEscrowHelper",
            dependencies: ["ManagedEncryptionEscrowXPC"],
            path: "Sources/ManagedEncryptionEscrowHelper"
        ),
        .testTarget(
            name: "ManagedEncryptionEscrowAppTests",
            dependencies: ["ManagedEncryptionEscrowApp", "ManagedEncryptionEscrowXPC"],
            path: "Tests/ManagedEncryptionEscrowAppTests"
        )
    ]
)
