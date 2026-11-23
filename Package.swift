// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FamilyRelay", platforms: [.macOS(.v14)], products: [.executable(name: "FamilyRelay", targets: ["FamilyRelay"])], targets: [.executableTarget(name: "FamilyRelay", resources: [.process("Resources")]), .testTarget(name: "FamilyRelayTests", dependencies: ["FamilyRelay"])], swiftLanguageModes: [.v5])
