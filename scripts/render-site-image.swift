import AppKit
import Foundation

// Website sharing image. Reuse the app's generated icon rather than redraw it.
let iconURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
NSColor(calibratedRed: 0.933, green: 0.957, blue: 0.945, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 630)).fill()
NSImage(contentsOf: iconURL)!.draw(in: NSRect(x: 68, y: 432, width: 112, height: 112))
let ink = NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.20, alpha: 1)
let titleFont = NSFont.systemFont(ofSize: 74, weight: .heavy)
let bodyFont = NSFont.systemFont(ofSize: 50, weight: .bold)
("HelloChat" as NSString).draw(at: NSPoint(x: 208, y: 450), withAttributes: [.font: titleFont, .foregroundColor: ink])
("Say Hello Chat to start Codex Voice,\nand Bye Chat to end it." as NSString).draw(
    in: NSRect(x: 72, y: 170, width: 1060, height: 180),
    withAttributes: [.font: bodyFont, .foregroundColor: ink])
NSColor(calibratedRed: 0.26, green: 0.83, blue: 0.67, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 72, y: 99, width: 1056, height: 12), xRadius: 6, yRadius: 6).fill()
NSGraphicsContext.restoreGraphicsState()
try pixels.representation(using: .png, properties: [:])!.write(to: outputURL)
