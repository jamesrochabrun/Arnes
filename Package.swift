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
    // 0.2.0 carries `Message.reasoningDetails` (the slot a tool loop replays signed/encrypted
    // reasoning through), the `reasoning_effort` wire pin and sorted-keys request encoding —
    // three changes made upstream in OpenRouterSwift. Nothing older builds this tree.
    .package(url: "https://github.com/jamesrochabrun/OpenRouterSwift", from: "0.2.0"),
    // OpenRouterSwift's injectable HTTP client is a SwiftOpenAI protocol; the gateway
    // transport (URL rewriting for LiteLLM-style providers) implements it.
    // 4.6.1 declares the transport's SwiftNIO products so clean Linux builds succeed.
    .package(url: "https://github.com/jamesrochabrun/SwiftOpenAI", from: "4.6.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/JohnSundell/Splash", from: "0.16.0"),
  ],
  targets: [
    .target(name: "CArnesProcess"),
    .target(
      name: "ArnesKit",
      dependencies: [
        .product(name: "OpenRouterSwift", package: "OpenRouterSwift"),
        .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
        .target(name: "CArnesProcess", condition: .when(platforms: [.linux])),
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
      dependencies: [
        "ArnesKit",
        .product(name: "SwiftOpenAI", package: "SwiftOpenAI"), // HTTPClient stubs for the gateway tests
      ]),
    .testTarget(
      name: "ArnesCLITests",
      dependencies: ["arnes"]),
  ])
