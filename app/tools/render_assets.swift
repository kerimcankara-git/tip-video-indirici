// Logodan (svg/png) uygulama ikonunu (AppIcon.iconset) üretir.
// Kullanım: swift app/tools/render_assets.swift <logo> <çıktı klasörü>
// Renk ve yerleşim ayarları ortam değişkenlerinden gelir (bkz. brands/*/brand.conf).
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else {
    fatalError("Kullanım: render_assets.swift <logo> <çıktı klasörü>")
}
let outDir = URL(fileURLWithPath: args[2])
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let env = ProcessInfo.processInfo.environment
func color(_ key: String, _ fallback: String) -> NSColor {
    let hex = UInt32(env[key] ?? fallback, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                   blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
func number(_ key: String, _ fallback: CGFloat) -> CGFloat { env[key].flatMap(Double.init).map { CGFloat($0) } ?? fallback }

let bgTop = color("ICON_BG_TOP", "dc343b")
let bgBottom = color("ICON_BG_BOTTOM", "a81f26")
let badgeFill = color("BADGE_FILL", "ffffff")
let badgeGlyph = color("BADGE_GLYPH", "dc343b")
let gloss = number("ICON_GLOSS", 0.18)
let logoScale = number("LOGO_SCALE", 0.6)
let badgeSize = number("BADGE_SIZE", 0.30)
let badgeY = number("BADGE_Y", 0.17)   // rozet merkezinin zeminin altından yüksekliği (oran)

func png(width: Int, height: Int, draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func drawLogo(in rect: NSRect, widthRatio: CGFloat) {
    let w = rect.width * widthRatio
    let h = w * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
}

// macOS ikon ızgarası: 1024'lük tuvalde 824'lük yuvarlatılmış kare
func drawIcon(_ canvas: NSRect) {
    let s = canvas.width
    let body = canvas.insetBy(dx: s * 100 / 1024, dy: s * 100 / 1024)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    bgTop.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: bgBottom, ending: bgTop)!.draw(in: path, angle: 90)
    if gloss > 0 {   // üstte hafif parlaklık
        NSGradient(colors: [NSColor.white.withAlphaComponent(gloss), NSColor.white.withAlphaComponent(0)])!
            .draw(in: path, angle: -90)
    }

    // Logo ortada; indirme rozeti orta altta, gerekirse logonun üstüne biner
    let b = body.width
    drawLogo(in: body, widthRatio: logoScale)
    // Halka rengi: rozetin oturduğu yerdeki zemin rengi (logodan ayırır)
    drawBadge(center: NSPoint(x: body.midX, y: body.minY + b * badgeY), diameter: b * badgeSize,
              ring: b * 0.035, ringColor: bgBottom.blended(withFraction: 0.2, of: bgTop) ?? bgBottom)
}

/// "Video İndirici" rozeti: beyaz daire içinde aşağı bakan oynat üçgeni + indirme çizgisi
func drawBadge(center c: NSPoint, diameter d: CGFloat, ring: CGFloat, ringColor: NSColor) {
    let circle = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)

    // Logodan ayırmak için zemin renginde halka (kesik görünümü)
    ringColor.setFill()
    NSBezierPath(ovalIn: circle.insetBy(dx: -ring, dy: -ring)).fill()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = d * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -d * 0.02)
    shadow.set()
    badgeFill.setFill()
    NSBezierPath(ovalIn: circle).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Aşağı bakan, köşeleri yuvarlatılmış üçgen
    let tw = d * 0.40, th = d * 0.32, round = d * 0.07
    let top = c.y + d * 0.21
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: c.x - tw / 2, y: top))
    tri.line(to: NSPoint(x: c.x + tw / 2, y: top))
    tri.line(to: NSPoint(x: c.x, y: top - th))
    tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = round
    badgeGlyph.set()
    tri.fill()
    tri.stroke()

    // İndirme çizgisi
    let barW = d * 0.44, barH = d * 0.075
    let bar = NSRect(x: c.x - barW / 2, y: top - th - d * 0.16, width: barW, height: barH)
    NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(width: px, height: px, draw: drawIcon).write(to: iconset.appendingPathComponent(name))
    }
}


print("✓ ikonlar üretildi")
