// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "HelloChat",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])],
    targets: [.executableTarget(name: "HelloChat", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
        path: "Sources",
        linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
                         .linkedFramework("CoreAudio"), .linkedFramework("AVFoundation"), .linkedFramework("SwiftUI")])],
    swiftLanguageModes: [.v5]
)
