// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Operator",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Operator", targets: ["Operator"])],
  dependencies: [
    .package(path: "Vendor/SwiftTerm"),
    .package(
      url: "https://github.com/swiftlang/swift-cmark.git",
      revision: "0101bf2c6ff6a218f93150f340fe5ccf76d9f3aa"),
  ],
  targets: [
    .target(
      name: "OperatorNotificationBridge",
      path: "Sources/OperatorNotificationBridge",
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("UserNotifications")]
    ),
    .executableTarget(
      name: "Operator",
      dependencies: [
        "OperatorNotificationBridge",
        "SwiftTerm",
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
      ],
      path: "Sources/Operator",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "OperatorTests",
      dependencies: ["Operator", "OperatorNotificationBridge"],
      path: "Tests/OperatorTests"
    ),
    .testTarget(
      name: "OperatorIntegrationTests",
      dependencies: ["Operator"],
      path: "Tests/OperatorIntegrationTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
