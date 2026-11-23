// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MessagingBridge", platforms: [.macOS(.v14)], products: [.executable(name: "MessagingBridge", targets: ["MessagingBridge"])], targets: [.executableTarget(name: "MessagingBridge", resources: [.process("Resources")]), .testTarget(name: "MessagingBridgeTests", dependencies: ["MessagingBridge"])], swiftLanguageModes: [.v5])
