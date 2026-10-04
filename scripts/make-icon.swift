// Draws the Everboard app icon and writes an .icns. Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Everboard.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: ~10% margin, continuous-corner squircle.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.47, green: 0.22, blue: 0.93, alpha: 1)])!.draw(in: shape, angle: -60)
    // 2×2 board of tiles; one tile "lit" as the notification.
    let pad = rect.width * 0.2, gap = rect.width * 0.08
    let tile = (rect.width - 2 * pad - gap) / 2
    for row in 0..<2 {
        for col in 0..<2 {
            let r = NSRect(x: rect.minX + pad + CGFloat(col) * (tile + gap), y: rect.minY + pad + CGFloat(row) * (tile + gap),
                           width: tile, height: tile)
            let lit = row == 1 && col == 1
            (lit ? NSColor(calibratedRed: 1, green: 0.78, blue: 0.25, alpha: 1) : NSColor.white.withAlphaComponent(0.88)).setFill()
            NSBezierPath(roundedRect: r, xRadius: tile * 0.24, yRadius: tile * 0.24).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
