// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "HelloChat",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
                   .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")],
    targets: [.executableTarget(name: "HelloChat", dependencies: [.product(name: "FluidAudio", package: "FluidAudio"),
                                                                  .product(name: "Sparkle", package: "Sparkle")],
        path: "Sources",
        linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
                         .linkedFramework("CoreAudio"), .linkedFramework("AVFoundation"), .linkedFramework("SwiftUI"),
                         .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])],
    swiftLanguageModes: [.v5]
)
