import AppKit
import Foundation
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    // Explicit pixels keep generated icons independent of the connected display's scale.
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 210, yRadius: 210).fill()
    NSColor(calibratedRed: 0.26, green: 0.83, blue: 0.67, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 170, y: 240, width: 684, height: 550), xRadius: 155, yRadius: 155).fill()
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 320, y: 270)); tail.line(to: NSPoint(x: 260, y: 130)); tail.line(to: NSPoint(x: 475, y: 265)); tail.close(); tail.fill()
    NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.20, alpha: 1).setFill()
    for (i, height) in [100.0, 220, 330, 180, 110].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 300 + Double(i) * 88, y: 520 - height / 2, width: 48, height: height), xRadius: 24, yRadius: 24).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination + "/icon-\(size).png"))
}
