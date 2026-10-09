import SwiftUI

/// The characters the user can pick from. Each one draws itself from the same `BuddyPose`.
public enum BuddyStyle: String, CaseIterable, Identifiable, Sendable {
    case blobby, pixel, bot
    public var id: String { rawValue }
    public var title: String {
        switch self { case .blobby: "Blobby"; case .pixel: "Pixel"; case .bot: "Bolt" }
    }
}

enum BuddyMouth { case smile, open, flat, frown, cheer }
enum BuddyEyes { case open, wide, closed, happy, cross }

/// One frame of animation, worked out from the mood and time. Characters only draw it.
struct BuddyPose {
    var x: CGFloat = 0          // sideways shake, design units
    var y: CGFloat = 0          // lift off the ground (>= 0)
    var squash: CGFloat = 0     // > 0 wider and flatter
    var lean: Double = 0        // degrees
    var look: CGFloat = 0       // -1...1 where the eyes point
    var eyes: BuddyEyes = .open
    var mouth: BuddyMouth = .smile
    var armL: Double = 20       // degrees from hanging down, + raises outward
    var armR: Double = 20
    var feet: CGFloat = 0       // -1...1 foot swing

    static func make(_ mood: BuddyMood, t: Double, speed: Double = 1) -> BuddyPose {
        var p = BuddyPose()
        let blink = fmod(t, 3.4) < 0.12
        switch mood {
        case .sleeping:
            p.squash = CGFloat(sin(t * 1.6)) * 0.04
            p.eyes = .closed; p.mouth = .flat; p.armL = 8; p.armR = 8; p.lean = sin(t * 0.8) * 2
        case .busy:
            let s = t * 7 * speed
            p.y = CGFloat(abs(sin(s))) * 7
            p.squash = CGFloat(cos(s * 2)) * 0.05
            p.look = CGFloat(sin(t * 1.3))
            p.armL = 35 + sin(s) * 35; p.armR = 35 - sin(s) * 35
            p.feet = CGFloat(sin(s)); p.lean = sin(s) * 3
            p.eyes = blink ? .closed : .open
        case .needsYou:
            let s = t * 5
            p.y = CGFloat(abs(sin(s))) * 16
            p.squash = CGFloat(cos(s * 2)) * 0.08
            p.armL = 25; p.armR = 150 + sin(t * 14) * 28     // right arm waves overhead
            p.eyes = .wide; p.mouth = .open; p.lean = sin(s) * 4
        case .error:
            p.x = CGFloat(sin(t * 38)) * 1.6
            p.eyes = .cross; p.mouth = .frown; p.armL = 5; p.armR = 5; p.squash = -0.04
        case .celebrating:
            let s = t * 6
            p.y = CGFloat(abs(sin(s))) * 20
            p.squash = CGFloat(cos(s * 2)) * 0.1
            p.armL = 140 + sin(t * 12) * 15; p.armR = 140 - sin(t * 12) * 15
            p.eyes = .happy; p.mouth = .cheer; p.lean = sin(s) * 6
        }
        return p
    }
}

/// Shared colors.
public enum BuddyPalette {
    public static func accent(_ m: BuddyMood) -> Color {
        switch m {
        case .needsYou: Color(red: 1.0, green: 0.62, blue: 0.1)
        case .error: Color(red: 0.93, green: 0.26, blue: 0.3)
        case .celebrating: Color(red: 0.62, green: 0.4, blue: 0.95)
        case .busy: Color(red: 0.2, green: 0.78, blue: 0.62)
        case .sleeping: Color(red: 0.45, green: 0.6, blue: 0.95)
        }
    }
}

/// A character at one moment: `t` is seconds, `mood` the feeling. Draws in a 100×100 box.
public struct BuddyView: View {
    var style: BuddyStyle
    var mood: BuddyMood
    var t: Double
    var speed: Double = 1
    var facingLeft = false

    public init(style: BuddyStyle, mood: BuddyMood, t: Double, speed: Double = 1, facingLeft: Bool = false) {
        self.style = style; self.mood = mood; self.t = t; self.speed = speed; self.facingLeft = facingLeft
    }

    public var body: some View {
        let pose = BuddyPose.make(mood, t: t, speed: speed)
        ZStack {
            Canvas { ctx, size in
                let k = min(size.width, size.height) / 100
                var c = ctx
                c.translateBy(x: (size.width - 100 * k) / 2, y: (size.height - 100 * k) / 2)
                c.scaleBy(x: k * (facingLeft ? -1 : 1), y: k)
                if facingLeft { c.translateBy(x: -100, y: 0) }
                BuddyArt.shadow(&c, pose)
                switch style {
                case .blobby: BuddyArt.blobby(&c, pose, mood)
                case .pixel: BuddyArt.pixel(&c, pose, mood)
                case .bot: BuddyArt.bot(&c, pose, mood, t)
                }
                BuddyArt.extras(&c, mood, t)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

enum BuddyArt {
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.2)

    static func shadow(_ c: inout GraphicsContext, _ p: BuddyPose) {
        let w = 46 - p.y * 0.8
        c.fill(Path(ellipseIn: CGRect(x: 50 - w / 2 + p.x, y: 90, width: w, height: 6)), with: .color(.black.opacity(0.18)))
    }

    // MARK: Face parts (shared)

    static func eyes(_ c: inout GraphicsContext, _ p: BuddyPose, at l: CGPoint, _ r: CGPoint, size: CGFloat, color: Color = ink) {
        for (i, pt) in [l, r].enumerated() {
            let look = p.look * size * 0.25
            switch p.eyes {
            case .open, .wide:
                let s = p.eyes == .wide ? size * 1.2 : size
                let rect = CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s * 1.1)
                c.fill(Path(ellipseIn: rect), with: .color(color))
                let g = s * 0.34
                c.fill(Path(ellipseIn: CGRect(x: pt.x - g / 2 + look + s * 0.12, y: pt.y - s * 0.28, width: g, height: g)), with: .color(.white))
            case .closed:
                var path = Path(); path.move(to: CGPoint(x: pt.x - size / 2, y: pt.y))
                path.addQuadCurve(to: CGPoint(x: pt.x + size / 2, y: pt.y), control: CGPoint(x: pt.x, y: pt.y + size * 0.45))
                c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            case .happy:
                var path = Path(); path.move(to: CGPoint(x: pt.x - size / 2, y: pt.y + size * 0.2))
                path.addQuadCurve(to: CGPoint(x: pt.x + size / 2, y: pt.y + size * 0.2), control: CGPoint(x: pt.x, y: pt.y - size * 0.7))
                c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            case .cross:
                let h = size * 0.4
                var path = Path()
                path.move(to: CGPoint(x: pt.x - h, y: pt.y - h)); path.addLine(to: CGPoint(x: pt.x + h, y: pt.y + h))
                path.move(to: CGPoint(x: pt.x + h, y: pt.y - h)); path.addLine(to: CGPoint(x: pt.x - h, y: pt.y + h))
                c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            }
            _ = i
        }
    }

    static func mouth(_ c: inout GraphicsContext, _ p: BuddyPose, at m: CGPoint, width w: CGFloat, color: Color = ink) {
        switch p.mouth {
        case .smile:
            var path = Path(); path.move(to: CGPoint(x: m.x - w / 2, y: m.y))
            path.addQuadCurve(to: CGPoint(x: m.x + w / 2, y: m.y), control: CGPoint(x: m.x, y: m.y + w * 0.5))
            c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        case .flat:
            var path = Path(); path.move(to: CGPoint(x: m.x - w * 0.25, y: m.y)); path.addLine(to: CGPoint(x: m.x + w * 0.25, y: m.y))
            c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        case .frown:
            var path = Path(); path.move(to: CGPoint(x: m.x - w / 2, y: m.y + w * 0.25))
            path.addQuadCurve(to: CGPoint(x: m.x + w / 2, y: m.y + w * 0.25), control: CGPoint(x: m.x, y: m.y - w * 0.2))
            c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        case .open:
            c.fill(Path(ellipseIn: CGRect(x: m.x - w * 0.28, y: m.y - w * 0.05, width: w * 0.56, height: w * 0.62)), with: .color(color))
        case .cheer:
            var path = Path(); path.move(to: CGPoint(x: m.x - w / 2, y: m.y)); path.addLine(to: CGPoint(x: m.x + w / 2, y: m.y))
            path.addQuadCurve(to: CGPoint(x: m.x - w / 2, y: m.y), control: CGPoint(x: m.x, y: m.y + w * 1.1))
            c.fill(path, with: .color(color))
        }
    }

    static func arm(_ c: inout GraphicsContext, shoulder s: CGPoint, side: CGFloat, angle: Double, length: CGFloat,
                    color: Color, width: CGFloat = 6) {
        // 0° hangs down; larger raises the arm outward then overhead.
        let a = angle * .pi / 180
        let end = CGPoint(x: s.x + side * CGFloat(sin(a)) * length, y: s.y + CGFloat(cos(a)) * length)
        var path = Path(); path.move(to: s); path.addLine(to: end)
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    // MARK: Blobby: a soft round blob

    static func blobby(_ c: inout GraphicsContext, _ p: BuddyPose, _ mood: BuddyMood) {
        let body = Color(red: 0.42, green: 0.86, blue: 0.72)
        let dark = Color(red: 0.25, green: 0.66, blue: 0.56)
        let w = 56 * (1 + p.squash), h = 54 * (1 - p.squash)
        let cx = 50 + p.x, base = 88 - p.y
        var g = c
        g.translateBy(x: cx, y: base); g.rotate(by: .degrees(p.lean)); g.translateBy(x: -cx, y: -base)
        // feet
        for s in [-1.0, 1.0] {
            let f = CGFloat(s) * p.feet * 4
            g.fill(Path(ellipseIn: CGRect(x: cx + CGFloat(s) * 13 - 7 + f, y: base - 5, width: 14, height: 8)), with: .color(dark))
        }
        arm(&g, shoulder: CGPoint(x: cx - w / 2 + 3, y: base - h * 0.5), side: -1, angle: p.armL, length: 17, color: dark, width: 7)
        arm(&g, shoulder: CGPoint(x: cx + w / 2 - 3, y: base - h * 0.5), side: 1, angle: p.armR, length: 17, color: dark, width: 7)
        let rect = CGRect(x: cx - w / 2, y: base - h, width: w, height: h)
        g.fill(Path(roundedRect: rect, cornerRadius: h * 0.48), with: .linearGradient(
            Gradient(colors: [body, dark]), startPoint: CGPoint(x: cx, y: base - h), endPoint: CGPoint(x: cx, y: base)))
        g.fill(Path(ellipseIn: CGRect(x: cx - w * 0.32, y: base - h * 0.9, width: w * 0.28, height: h * 0.16)), with: .color(.white.opacity(0.35)))
        let eyeY = base - h * 0.55
        eyes(&g, p, at: CGPoint(x: cx - 11, y: eyeY), CGPoint(x: cx + 11, y: eyeY), size: 8.5)
        g.fill(Path(ellipseIn: CGRect(x: cx - 21, y: eyeY + 7, width: 7, height: 4.5)), with: .color(.pink.opacity(0.5)))
        g.fill(Path(ellipseIn: CGRect(x: cx + 14, y: eyeY + 7, width: 7, height: 4.5)), with: .color(.pink.opacity(0.5)))
        mouth(&g, p, at: CGPoint(x: cx, y: eyeY + 11), width: 9)
    }

    // MARK: Pixel: a retro critter on a 16×16 grid

    private static let pixelBody: [String] = [
        "................",
        "...O........O...",
        "...OO......OO...",
        "..OOOOOOOOOOOO..",
        ".OOOOOOOOOOOOOO.",
        ".OOOOOOOOOOOOOO.",
        ".OOOOOOOOOOOOOO.",
        ".OOOOOOOOOOOOOO.",
        ".OOOOOOOOOOOOOO.",
        ".OOOOOOOOOOOOOO.",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOO......OOO..",
        "................",
    ]

    static func pixel(_ c: inout GraphicsContext, _ p: BuddyPose, _ mood: BuddyMood) {
        let body = Color(red: 1.0, green: 0.55, blue: 0.62)
        let shade = Color(red: 0.86, green: 0.36, blue: 0.5)
        let u: CGFloat = 5                       // size of one pixel
        let ox = 50 - 8 * u + p.x, oy = 92 - 14 * u - p.y
        let sq = 1 + p.squash * 0.6
        var g = c
        g.translateBy(x: 50 + p.x, y: 92 - p.y); g.rotate(by: .degrees(p.lean * 0.6)); g.translateBy(x: -50 - p.x, y: -92 + p.y)
        g.translateBy(x: 50 + p.x, y: 92 - p.y); g.scaleBy(x: sq, y: 2 - sq); g.translateBy(x: -50 - p.x, y: -92 + p.y)
        for (r, row) in pixelBody.enumerated() {
            for (col, ch) in row.enumerated() where ch == "O" {
                var cell = CGRect(x: ox + CGFloat(col) * u, y: oy + CGFloat(r) * u, width: u + 0.4, height: u + 0.4)
                if r >= 12 { cell.origin.x += CGFloat(col < 8 ? -1 : 1) * p.feet * 3 }
                g.fill(Path(cell), with: .color(r >= 10 || col == 1 || col == 14 ? shade : body))
            }
        }
        // arms are pixel stubs
        let shoulderY = oy + 7 * u
        for (side, ang) in [(-1.0, p.armL), (1.0, p.armR)] {
            let x = side < 0 ? ox : ox + 16 * u
            arm(&g, shoulder: CGPoint(x: x, y: shoulderY), side: CGFloat(side), angle: ang, length: 12, color: shade, width: u)
        }
        let ey = oy + 6.5 * u
        var face = g
        face.translateBy(x: 0, y: 0)
        eyes(&face, p, at: CGPoint(x: ox + 5 * u, y: ey), CGPoint(x: ox + 11 * u, y: ey), size: 7, color: Color(red: 0.2, green: 0.08, blue: 0.2))
        mouth(&face, p, at: CGPoint(x: ox + 8 * u, y: oy + 8.6 * u), width: 8, color: Color(red: 0.2, green: 0.08, blue: 0.2))
    }

    // MARK: Bolt: a little round robot

    static func bot(_ c: inout GraphicsContext, _ p: BuddyPose, _ mood: BuddyMood, _ t: Double) {
        let metal = Color(red: 0.82, green: 0.86, blue: 0.95)
        let edge = Color(red: 0.5, green: 0.56, blue: 0.72)
        let screen = Color(red: 0.1, green: 0.13, blue: 0.24)
        let led = BuddyPalette.accent(mood)
        let cx = 50 + p.x, base = 89 - p.y
        let w = 54 * (1 + p.squash), h = 48 * (1 - p.squash)
        var g = c
        g.translateBy(x: cx, y: base); g.rotate(by: .degrees(p.lean)); g.translateBy(x: -cx, y: -base)
        // legs
        for s in [-1.0, 1.0] {
            g.fill(Path(roundedRect: CGRect(x: cx + CGFloat(s) * 11 - 4 + CGFloat(s) * p.feet * 3, y: base - 6, width: 8, height: 8), cornerRadius: 3), with: .color(edge))
        }
        arm(&g, shoulder: CGPoint(x: cx - w / 2, y: base - h * 0.45), side: -1, angle: p.armL, length: 17, color: edge, width: 6)
        arm(&g, shoulder: CGPoint(x: cx + w / 2, y: base - h * 0.45), side: 1, angle: p.armR, length: 17, color: edge, width: 6)
        // antenna
        let top = base - h
        var ant = Path(); ant.move(to: CGPoint(x: cx, y: top)); ant.addLine(to: CGPoint(x: cx + CGFloat(sin(t * 3)) * 2, y: top - 9))
        g.stroke(ant, with: .color(edge), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        let glow = mood == .sleeping ? 0.45 : (0.7 + 0.3 * sin(t * 8))
        let bulb = CGRect(x: cx - 4.5 + CGFloat(sin(t * 3)) * 2, y: top - 15, width: 9, height: 9)
        g.fill(Path(ellipseIn: bulb.insetBy(dx: -3, dy: -3)), with: .color(led.opacity(0.25 * glow)))
        g.fill(Path(ellipseIn: bulb), with: .color(led.opacity(glow)))
        // head
        let rect = CGRect(x: cx - w / 2, y: top, width: w, height: h)
        g.fill(Path(roundedRect: rect, cornerRadius: 17), with: .linearGradient(
            Gradient(colors: [.white, metal]), startPoint: CGPoint(x: cx, y: top), endPoint: CGPoint(x: cx, y: base)))
        g.stroke(Path(roundedRect: rect, cornerRadius: 17), with: .color(edge), lineWidth: 2)
        let sr = rect.insetBy(dx: 7, dy: 8).offsetBy(dx: 0, dy: -1)
        g.fill(Path(roundedRect: sr, cornerRadius: 11), with: .color(screen))
        let ey = sr.minY + sr.height * 0.4
        eyes(&g, p, at: CGPoint(x: cx - 10, y: ey), CGPoint(x: cx + 10, y: ey), size: 7, color: led)
        mouth(&g, p, at: CGPoint(x: cx, y: ey + 9), width: 9, color: led)
    }

    // MARK: Extras: zzz, "!", sweat, confetti

    static func extras(_ c: inout GraphicsContext, _ mood: BuddyMood, _ t: Double) {
        switch mood {
        case .sleeping:
            for i in 0..<3 {
                let ph = fmod(t * 0.5 + Double(i) / 3, 1)
                let text = Text("z").font(.system(size: 9 + CGFloat(ph) * 9, weight: .heavy, design: .rounded))
                    .foregroundColor(BuddyPalette.accent(.sleeping).opacity(1 - ph))
                c.draw(text, at: CGPoint(x: 70 + CGFloat(ph) * 14, y: 34 - CGFloat(ph) * 20))
            }
        case .needsYou:
            let pulse = 1 + 0.18 * sin(t * 9)
            var g = c
            g.translateBy(x: 24, y: 20); g.scaleBy(x: pulse, y: pulse)
            g.fill(Path(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20)), with: .color(BuddyPalette.accent(.needsYou)))
            g.draw(Text("!").font(.system(size: 17, weight: .black, design: .rounded)).foregroundColor(.white), at: .zero)
        case .error:
            let drip = CGFloat(fmod(t * 1.2, 1))
            var d = Path(); d.move(to: CGPoint(x: 74, y: 24 + drip * 8))
            d.addQuadCurve(to: CGPoint(x: 74, y: 40 + drip * 8), control: CGPoint(x: 82, y: 33 + drip * 8))
            d.addQuadCurve(to: CGPoint(x: 74, y: 24 + drip * 8), control: CGPoint(x: 66, y: 33 + drip * 8))
            c.fill(d, with: .color(Color(red: 0.4, green: 0.7, blue: 1).opacity(1 - Double(drip) * 0.6)))
        case .celebrating:
            let colors: [Color] = [.pink, .yellow, .cyan, .orange, .purple, .mint]
            for i in 0..<14 {
                let seed = Double(i) * 7.31
                let ph = fmod(t * 0.9 + seed.truncatingRemainder(dividingBy: 1), 1)
                let x = 12 + CGFloat(fmod(seed * 13, 76))
                let y = -4 + CGFloat(ph) * 70
                var g = c
                g.translateBy(x: x + CGFloat(sin(t * 4 + seed)) * 4, y: y); g.rotate(by: .degrees(t * 220 + seed * 40))
                g.fill(Path(CGRect(x: -2.5, y: -1.5, width: 5, height: 3)), with: .color(colors[i % colors.count].opacity(1 - ph * 0.5)))
            }
        case .busy:
            for i in 0..<2 {
                let ph = fmod(t * 1.1 + Double(i) * 0.5, 1)
                c.fill(Path(ellipseIn: CGRect(x: 18 - CGFloat(ph) * 10, y: 70 + CGFloat(i) * 8, width: 5 * (1 - ph) + 1, height: 5 * (1 - ph) + 1)),
                       with: .color(.gray.opacity(0.5 * (1 - ph))))
            }
        }
    }
}
