// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TOP75",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TOP75", targets: ["TOP75"])],
    targets: [.executableTarget(name: "TOP75")]
)
