// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NikonUSBExport",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "NikonUSBExport", path: "shared"),
        .testTarget(name: "NikonUSBExportTests", dependencies: ["NikonUSBExport"], path: "tests")
    ]
)
