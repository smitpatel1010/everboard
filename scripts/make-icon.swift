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

/// One isometric layer: a rhombus with softly rounded corners, centered at `center`.
func layer(_ center: CGPoint, width: CGFloat, height: CGFloat, radius: CGFloat = 46) -> CGPath {
    let top = CGPoint(x: center.x, y: center.y - height / 2), right = CGPoint(x: center.x + width / 2, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y + height / 2), left = CGPoint(x: center.x - width / 2, y: center.y)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (top.x + left.x) / 2, y: (top.y + left.y) / 2))
    p.addArc(tangent1End: top, tangent2End: right, radius: radius)
    p.addArc(tangent1End: right, tangent2End: bottom, radius: radius)
    p.addArc(tangent1End: bottom, tangent2End: left, radius: radius)
    p.addArc(tangent1End: left, tangent2End: top, radius: radius)
    p.closeSubpath()
    return p
}

// The app's mark: three stacked boards (your sources, layered into one view) on the indigo-to-violet accent.
func draw(_ c: CGContext, _ k: CGFloat) {
    let tile = squircle(body)
    c.shadowed(k, y: 12, blur: 28, hex(0x000000, 0.35)) { c.fill(tile, hex(0x6B5CFA)) }
    c.saveGState(); c.addPath(tile); c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [hex(0x7C6CFF), hex(0x6A4FF0), hex(0xA154EA)] as CFArray, locations: [0, 0.5, 1])!,
                         start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    c.fill(tile, glow: 0xFFFFFF, 0.22, at: CGPoint(x: 290, y: 170), radius: 560)
    c.fill(tile, glow: 0xFF7AC6, 0.20, at: CGPoint(x: 860, y: 880), radius: 420)
    // Top-lit rim, like light catching the edge of glass.
    c.saveGState(); c.addPath(tile); c.clip()
    c.addPath(tile); c.setLineWidth(10); c.replacePathWithStrokedPath(); c.clip()
    c.fill(tile, vertical: [hex(0xffffff, 0.38), hex(0xffffff, 0.04)], from: body.minY, to: body.maxY)
    c.restoreGState()

    // Three layers, back to front; the front one is solid white.
    let w: CGFloat = 520, h: CGFloat = 300, step: CGFloat = 112
    let centerY: CGFloat = 512
    let layers: [(CGFloat, CGFloat)] = [(centerY + step, 0.42), (centerY, 0.68), (centerY - step, 1.0)]
    for (y, alpha) in layers {
        let path = layer(CGPoint(x: 512, y: y), width: w, height: h)
        c.shadowed(k, y: 14, blur: 26, hex(0x2A1580, 0.35)) { c.fill(path, hex(0xffffff, alpha)) }
    }
    // A small lit dot on the front layer: something needs you.
    let dot = CGPath(ellipseIn: CGRect(x: 512 - 34, y: centerY - step - 34, width: 68, height: 68), transform: nil)
    c.fill(dot, hex(0x7C5CFA))
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
