// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TOP75",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TOP75", targets: ["TOP75"])],
    targets: [.executableTarget(name: "TOP75", resources: [.process("Resources")])]
)
