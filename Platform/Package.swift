// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacPhilosophyPlatformFoundation",
  platforms: [.macOS(.v13)],
  products: [
    .library(
      name: "MacPhilosophyPlatformFoundation",
      targets: ["PlatformContracts", "PlatformServices", "BuiltinFeatureCatalog"]
    )
  ],
  targets: [
    .target(
      name: "PlatformContracts",
      path: "Contracts"
    ),
    .target(
      name: "PlatformServices",
      dependencies: ["PlatformContracts"],
      path: "Services"
    ),
    .target(
      name: "BuiltinFeatureCatalog",
      dependencies: ["PlatformContracts"],
      path: "BuiltinFeatures"
    ),
    .testTarget(
      name: "PlatformFoundationTests",
      dependencies: ["PlatformContracts", "PlatformServices", "BuiltinFeatureCatalog"],
      path: "Tests/PlatformFoundationTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
