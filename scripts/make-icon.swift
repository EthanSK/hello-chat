// Render the approved Hail SVG for build.sh and prepare-site.py. — GPT-6.1 Sol
import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.svg")
guard let icon = NSImage(contentsOf: source) else {
    fatalError("Could not load the app icon at \(source.path)")
}
icon.cacheMode = .never
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    // Explicit pixels keep generated icons independent of the connected display's scale.
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSGraphicsContext.current!.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try representation.representation(using: .png, properties: [:])!.write(
        to: destination.appendingPathComponent("icon-\(size).png"))
}
