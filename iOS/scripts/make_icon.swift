// Draws the Session Watch "Gauge prompt" icon: two usage gauges (amber = Claude, teal = a second agent)
// around a terminal prompt (›_), on a #16181d tile. Vector paths only, 1024×1024 PNG.
//
//   swift scripts/make_icon.swift ios <out.png>   full-bleed square, no alpha (iOS masks it)
//   swift scripts/make_icon.swift mac <out.png>   macOS rounded tile, 824/1024 centred, transparent margin
//
// Geometry is authored on a 140×140 reference tile (y down) and scaled to the drawn tile.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, args[1] == "ios" || args[1] == "mac" else {
    FileHandle.standardError.write("usage: make_icon.swift ios|mac <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let mac = args[1] == "mac"
let out = args[2]

let size = 1024
let s = CGFloat(size)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let alpha: CGImageAlphaInfo = mac ? .premultipliedLast : .noneSkipLast
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: alpha.rawValue)!

func hex(_ v: UInt32) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255,
                                         CGFloat(v & 0xff) / 255, 1])!
}
let tileColor = hex(0x16181d), trackColor = hex(0x2a2e36)
let amber = hex(0xf5a524), teal = hex(0x3fc1b0), ink = hex(0xf3f4f6)

// The tile: full bleed on iOS; on macOS an 824pt rounded rect (22.4% radius) centred in the canvas.
let tileSide: CGFloat = mac ? 824 : s
let tileOrigin = (s - tileSide) / 2
if mac {
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let rect = CGRect(x: tileOrigin, y: tileOrigin, width: tileSide, height: tileSide)
    let r = tileSide * 0.224
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(tileColor)
    ctx.fillPath()
} else {
    ctx.setFillColor(tileColor)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
}

// Switch to reference space: 140×140, origin top-left, y down.
let k = tileSide / 140
ctx.translateBy(x: tileOrigin, y: tileOrigin + tileSide)
ctx.scaleBy(x: k, y: -k)

let centre = CGPoint(x: 70, y: 70)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

func ring(radius: CGFloat, width: CGFloat) {
    ctx.setStrokeColor(trackColor)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
}

// A gauge arc from 12 o'clock, clockwise on screen, to the given end point on the circle.
// In y-down space angles grow clockwise, so the top is -90° and the sweep runs in increasing angle.
func arc(radius: CGFloat, width: CGFloat, end: CGPoint, color: CGColor) {
    let start = -CGFloat.pi / 2
    var stop = atan2(end.y - centre.y, end.x - centre.x)
    while stop <= start { stop += 2 * .pi }
    let p = CGMutablePath()
    p.addArc(center: centre, radius: radius, startAngle: start, endAngle: stop, clockwise: false)
    ctx.addPath(p)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

ring(radius: 46, width: 9)
arc(radius: 46, width: 9, end: CGPoint(x: 26.3, y: 84.2), color: amber)
ring(radius: 32, width: 5)
arc(radius: 32, width: 5, end: CGPoint(x: 100.4, y: 80), color: teal)

// The prompt: chevron and underscore.
ctx.setStrokeColor(ink)
ctx.setLineWidth(5)
ctx.addLines(between: [CGPoint(x: 56, y: 61), CGPoint(x: 65, y: 70), CGPoint(x: 56, y: 79)])
ctx.strokePath()
ctx.addLines(between: [CGPoint(x: 70, y: 80), CGPoint(x: 84, y: 80)])
ctx.strokePath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
precondition(CGImageDestinationFinalize(dest))
print("wrote \(out) (\(args[1]))")
