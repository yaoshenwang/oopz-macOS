import AppKit

// Original geometric headphone mark. No imported artwork, fonts, or system symbol assets.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 215, yRadius: 215).fill()
        NSColor(red: 0.39, green: 0.61, blue: 1, alpha: 1).setStroke()
        let arch = NSBezierPath()
        arch.move(to: NSPoint(x: 272, y: 400))
        arch.line(to: NSPoint(x: 272, y: 520))
        arch.curve(to: NSPoint(x: 752, y: 520), controlPoint1: NSPoint(x: 272, y: 855), controlPoint2: NSPoint(x: 752, y: 855))
        arch.line(to: NSPoint(x: 752, y: 400))
        arch.lineWidth = 68; arch.lineCapStyle = .round; arch.stroke()
        NSColor.white.setFill()
        for x in [232, 688] { NSBezierPath(roundedRect: NSRect(x: x, y: 294, width: 104, height: 236), xRadius: 44, yRadius: 44).fill() }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: temporary.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", temporary.path, "-o", destination.path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
