// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Arnes",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(name: "ArnesKit", targets: ["ArnesKit"]),
    .executable(name: "arnes", targets: ["arnes"]),
  ],
  dependencies: [
    .package(url: "https://github.com/jamesrochabrun/OpenRouterSwift", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/JohnSundell/Splash", from: "0.16.0"),
  ],
  targets: [
    .target(
      name: "ArnesKit",
      dependencies: [
        .product(name: "OpenRouterSwift", package: "OpenRouterSwift"),
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency"),
      ]),
    .executableTarget(
      name: "arnes",
      dependencies: [
        "ArnesKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Splash", package: "Splash"),
      ]),
    .testTarget(
      name: "ArnesKitTests",
      dependencies: ["ArnesKit"]),
    .testTarget(
      name: "ArnesCLITests",
      dependencies: ["arnes"]),
  ])
