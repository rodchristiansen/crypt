// swift-tools-version:6.0

import PackageDescription

let package = Package(
  name: "Crypt",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "checkin", targets: ["checkin"]),
    .library(name: "CryptCore", targets: ["CryptCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "CryptCore",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "checkin",
      dependencies: [
        "CryptCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "CryptCoreTests",
      dependencies: ["CryptCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
