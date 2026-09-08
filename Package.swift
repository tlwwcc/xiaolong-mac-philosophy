// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "aixlg-hotkeys",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "aixlg-hotkeys", targets: ["aixlg-hotkeys"]),
    .executable(name: "aixlg-network-speed-status", targets: ["NetworkSpeedStatusHelper"]),
    .executable(name: "aixlg-sleep-status", targets: ["SleepStatusHelper"]),
    .library(name: "YoumuFeature", targets: ["YoumuFeature"]),
    .library(name: "PijuanPDFFeature", targets: ["PijuanPDFFeature"]),
  ],
  dependencies: [
    .package(path: "Platform"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
  ],
  targets: [
    .executableTarget(
      name: "aixlg-hotkeys",
      dependencies: [
        "YoumuFeature",
        "PijuanPDFFeature",
        .product(
          name: "MacPhilosophyPlatformFoundation",
          package: "platform"
        ),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Carbon"),
        .linkedFramework("IOKit"),
        .linkedFramework("QuickLookUI"),
        .linkedFramework("Security"),
        .linkedFramework("SwiftUI"),
        .linkedFramework("UniformTypeIdentifiers"),
        .linkedLibrary("sqlite3"),
        .unsafeFlags([
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ]),
      ]
    ),
    .target(
      name: "YoumuFeature",
      dependencies: [
        .product(
          name: "MacPhilosophyPlatformFoundation",
          package: "platform"
        )
      ],
      path: "IntegratedFeatures/YoumuFeature/Sources/YoumuFeature",
      swiftSettings: [
        .unsafeFlags(["-default-isolation", "MainActor"])
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreImage"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Security"),
        .linkedFramework("SwiftUI"),
        .linkedFramework("Translation"),
        .linkedFramework("UniformTypeIdentifiers"),
        .linkedFramework("Vision"),
      ]
    ),
    .target(
      name: "PijuanPDFFeature",
      path: "IntegratedFeatures/PijuanPDFFeature/Sources/PijuanPDFFeature",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("PDFKit"),
        .linkedFramework("SwiftUI"),
      ]
    ),
    .executableTarget(
      name: "NetworkSpeedStatusHelper",
      path: "HelperSources",
      linkerSettings: [
        .linkedFramework("AppKit")
      ]
    ),
    .executableTarget(
      name: "SleepStatusHelper",
      path: "SleepStatusHelperSources",
      linkerSettings: [
        .linkedFramework("AppKit")
      ]
    ),
    .testTarget(
      name: "YoumuFeatureTests",
      dependencies: [
        "YoumuFeature",
        .product(
          name: "MacPhilosophyPlatformFoundation",
          package: "platform"
        ),
      ],
      path: "IntegratedFeatures/YoumuFeature/Tests/YoumuFeatureTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
