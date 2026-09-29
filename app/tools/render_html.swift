// HTML şablonunu PDF'e ya da PNG'ye çevirir (kurulum rehberi ve DMG arka planı için).
//
//   swift app/tools/render_html.swift pdf <şablon.html> <çıktı.pdf>
//   swift app/tools/render_html.swift png <şablon.html> <çıktı.png> <genişlik> <yükseklik>
//
// Şablondaki {{ANAHTAR}} yerine TPL_ANAHTAR ortam değişkeni yazılır.
// TPL_ICON_FILE ve TPL_FONT_FILE verilirse {{ICON}} ve {{FONT}} dosyadan data: URI olarak gömülür.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 4, ["pdf", "png"].contains(args[1]) else {
    fatalError("Kullanım: render_html.swift pdf|png şablon çıktı [genişlik yükseklik]")
}
let mode = args[1]
let output = URL(fileURLWithPath: args[3])
let pngSize = args.count >= 6 ? CGSize(width: Double(args[4])!, height: Double(args[5])!) : .zero

var html = try String(contentsOfFile: args[2], encoding: .utf8)
let env = ProcessInfo.processInfo.environment
func dataURI(_ path: String, _ mime: String) -> String {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    return "data:\(mime);base64,\(data.base64EncodedString())"
}
if let icon = env["TPL_ICON_FILE"] { html = html.replacingOccurrences(of: "{{ICON}}", with: dataURI(icon, "image/png")) }
if let font = env["TPL_FONT_FILE"] { html = html.replacingOccurrences(of: "{{FONT}}", with: dataURI(font, "font/ttf")) }
for (key, value) in env where key.hasPrefix("TPL_") {
    html = html.replacingOccurrences(of: "{{\(key.dropFirst(4))}}", with: value)
}

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow

    init(width: CGFloat, height: CGFloat) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // Görünmez bir pencere; WebKit ancak bir pencerede çizim yapıyor
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fontlar ve görseller yüklensin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { mode == "pdf" ? self.pdf() : self.png() }
    }

    func pdf() {
        web.evaluateJavaScript("document.documentElement.scrollHeight") { h, _ in
            let height = CGFloat((h as? Double) ?? 1200)
            self.web.setFrameSize(NSSize(width: self.web.frame.width, height: height))
            self.window.setContentSize(self.web.frame.size)
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: self.web.frame.width, height: height)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.web.createPDF(configuration: config) { result in
                    switch result {
                    case .success(let data): try! data.write(to: output); exit(0)
                    case .failure(let e): fatalError("PDF üretilemedi: \(e)")
                    }
                }
            }
        }
    }

    func png() {
        web.takeSnapshot(with: nil) { image, error in
            guard let image else { fatalError("Görüntü alınamadı: \(String(describing: error))") }
            // Ekranın ölçeğinden bağımsız, tam istenen piksel boyutunda kaydet
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pngSize.width), pixelsHigh: Int(pngSize.height),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: pngSize))
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!.write(to: output)
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = mode == "pdf" ? Renderer(width: 860, height: 1200) : Renderer(width: pngSize.width, height: pngSize.height)
renderer.web.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fatalError("Zaman aşımı") }
app.run()
