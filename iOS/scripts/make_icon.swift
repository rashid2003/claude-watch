// Draws the ClaudeRemote app icon: a clay eight-spoke teardrop asterisk (✻) on near-black, 1024×1024, no alpha.
// Run from iOS/: swift scripts/make_icon.swift ClaudeRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
let s = CGFloat(size), c = CGPoint(x: s / 2, y: s / 2)

// Background: #121212 with a soft lift towards the top and a darker rim.
ctx.setFillColor(rgb(0x12 / 255.0, 0x12 / 255.0, 0x12 / 255.0)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.16, 0.15, 0.145), rgb(0.071, 0.071, 0.071), rgb(0.045, 0.045, 0.045)] as CFArray,
                    locations: [0, 0.62, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: c.x, y: s * 0.66), startRadius: 0,
                       endCenter: CGPoint(x: c.x, y: s * 0.55), endRadius: s * 0.78, options: [.drawsAfterEndLocation])
// A faint clay glow behind the glyph.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0.851, 0.467, 0.341, 0.20), rgb(0.851, 0.467, 0.341, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.42, options: [])

// The asterisk: eight teardrop spokes, narrow at the hub and rounded at the tip, around a round hub.
func spoke(angle: CGFloat) -> CGPath {
    let r0: CGFloat = 60, r1: CGFloat = 292     // hub end, centre of the tip cap
    let w0: CGFloat = 24, w1: CGFloat = 50      // half widths
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r0, y: -w0))
    p.addCurve(to: CGPoint(x: r1, y: -w1), control1: CGPoint(x: r0 + 90, y: -w0 - 2), control2: CGPoint(x: r1 - 110, y: -w1))
    p.addArc(center: CGPoint(x: r1, y: 0), radius: w1, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    p.addCurve(to: CGPoint(x: r0, y: w0), control1: CGPoint(x: r1 - 110, y: w1), control2: CGPoint(x: r0 + 90, y: w0 + 2))
    p.addArc(center: CGPoint(x: r0, y: 0), radius: w0, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    p.closeSubpath()
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
    return p.copy(using: &t)!
}

// One layer: solid shapes first, then the gradient and the highlight painted only where the shapes are,
// so overlapping spokes never show seams. The shadow under the layer gives the glyph some lift.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: rgb(0, 0, 0, 0.65))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(rgb(1, 1, 1))
for i in 0..<8 { ctx.addPath(spoke(angle: CGFloat(i) * .pi / 4 + .pi / 8)); ctx.fillPath() }
ctx.fillEllipse(in: CGRect(x: c.x - 84, y: c.y - 84, width: 168, height: 168))
ctx.setBlendMode(.sourceIn)
let clay = CGGradient(colorsSpace: cs, colors: [rgb(0.93, 0.57, 0.44), rgb(0.851, 0.467, 0.341), rgb(0.72, 0.36, 0.25)] as CFArray,
                      locations: [0, 0.5, 1])!
ctx.drawLinearGradient(clay, start: CGPoint(x: c.x - 260, y: c.y + 320), end: CGPoint(x: c.x + 260, y: c.y - 320), options: [])
ctx.setBlendMode(.sourceAtop)
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.14), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: c.x, y: c.y + 340), end: CGPoint(x: c.x, y: c.y), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
precondition(CGImageDestinationFinalize(dest))
print("wrote \(out)")
