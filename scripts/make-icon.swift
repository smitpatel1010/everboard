// Draws the Everboard app icon and writes an .icns. Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Everboard.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Everything is drawn in a 1024×1024, y-down space. macOS icon grid: an 824×824 body with a 100pt margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

// Continuous-corner squircle (superellipse), closer to Apple's icon shape than a rounded rect.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<720 {
        let t = CGFloat(i) / 720 * 2 * .pi, c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func pill(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

extension CGContext {
    func fill(_ path: CGPath, _ color: CGColor) { saveGState(); addPath(path); setFillColor(color); fillPath(); restoreGState() }
    func fill(_ path: CGPath, vertical colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
        saveGState(); addPath(path); clip()
        drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!,
                           start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }
    func fill(_ path: CGPath, glow color: UInt32, _ alpha: CGFloat, at center: CGPoint, radius: CGFloat) {
        saveGState(); addPath(path); clip()
        drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: [hex(color, alpha), hex(color, 0)] as CFArray, locations: nil)!,
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        restoreGState()
    }
    // Shadow offsets and blur are in device pixels, so they're scaled by `k` (pixels per point).
    func shadowed(_ k: CGFloat, y: CGFloat, blur: CGFloat, _ color: CGColor, _ draw: () -> Void) {
        saveGState(); setShadow(offset: CGSize(width: 0, height: -y * k), blur: blur * k, color: color); draw(); restoreGState()
    }
}

// The macOS grid grown into a tiny dashboard: a feed, a usage ring and a lit tile for what needs attention.
func draw(_ c: CGContext, _ k: CGFloat) {
    let tile = squircle(body)
    c.shadowed(k, y: 12, blur: 28, hex(0x000000, 0.35)) { c.fill(tile, hex(0x1E7BE8)) }
    c.saveGState(); c.addPath(tile); c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [hex(0x19C2B0), hex(0x1E7BE8), hex(0x2D3BC9)] as CFArray, locations: nil)!,
                         start: CGPoint(x: 160, y: body.minY), end: CGPoint(x: 860, y: body.maxY),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    c.fill(tile, glow: 0xFFFFFF, 0.25, at: CGPoint(x: 300, y: 160), radius: 520)
    // Top-lit rim, like light catching the edge of glass.
    c.saveGState(); c.addPath(tile); c.clip()
    c.addPath(tile); c.setLineWidth(10); c.replacePathWithStrokedPath(); c.clip()
    c.fill(tile, vertical: [hex(0xffffff, 0.35), hex(0xffffff, 0.04)], from: body.minY, to: body.maxY)
    c.restoreGState()

    // Bento: a tall feed tile on the left, a usage tile and a lit tile stacked on the right.
    let inner = body.insetBy(dx: 96, dy: 96), gap: CGFloat = 44, colW = (inner.width - gap) / 2
    let feed = CGRect(x: inner.minX, y: inner.minY, width: colW, height: inner.height)
    let usage = CGRect(x: inner.minX + colW + gap, y: inner.minY, width: colW, height: (inner.height - gap) / 2)
    let lit = CGRect(x: usage.minX, y: usage.maxY + gap, width: colW, height: usage.height)
    func card(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: 56, cornerHeight: 56, transform: nil) }
    for r in [feed, usage] {
        c.shadowed(k, y: 10, blur: 24, hex(0x0A1A5C, 0.35)) { c.fill(card(r), hex(0xffffff, 0.95)) }
    }
    c.shadowed(k, y: 10, blur: 24, hex(0xB34700, 0.45)) { c.fill(card(lit), hex(0xFFB020)) }
    c.fill(card(lit), vertical: [hex(0xFFD15A), hex(0xFF9F1C)], from: lit.minY, to: lit.maxY)

    for i in 0..<3 {
        let y = feed.minY + 58 + CGFloat(i) * 128, textW = feed.width - 152
        c.fill(CGPath(ellipseIn: CGRect(x: feed.minX + 40, y: y, width: 56, height: 56), transform: nil),
               i == 0 ? hex(0xFF9F1C) : hex(0x1E7BE8, 0.85))
        c.fill(pill(CGRect(x: feed.minX + 112, y: y + 6, width: textW, height: 22)), hex(0x1E3A8A, 0.8))
        c.fill(pill(CGRect(x: feed.minX + 112, y: y + 38, width: textW * 0.65, height: 18)), hex(0x1E3A8A, 0.25))
    }

    let center = CGPoint(x: usage.midX, y: usage.midY)
    c.saveGState(); c.setLineWidth(30); c.setLineCap(.round)
    c.setStrokeColor(hex(0x1E7BE8, 0.18)); c.addArc(center: center, radius: 72, startAngle: 0, endAngle: 2 * .pi, clockwise: false); c.strokePath()
    c.setStrokeColor(hex(0x19C2B0)); c.addArc(center: center, radius: 72, startAngle: -.pi / 2, endAngle: 0.95 * .pi, clockwise: false); c.strokePath()
    c.restoreGState()

    c.fill(CGPath(ellipseIn: CGRect(x: lit.midX - 40, y: lit.midY - 40, width: 80, height: 80), transform: nil), hex(0xffffff))
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let k = CGFloat(px) / 1024
    ctx.cgContext.translateBy(x: 0, y: CGFloat(px))
    ctx.cgContext.scaleBy(x: k, y: -k)
    draw(ctx.cgContext, k)
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
