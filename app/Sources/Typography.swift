import AppKit
import CoreText
import SwiftUI

/// Uygulamayla gelen değişken fontlar (Resources/Fonts). Adla değil doğrudan dosyadan yüklenir;
/// böylece sistemde aynı adla kurulu başka bir sürüm varsa karışmaz.
enum Typography {
    private static let wghtAxis = NSNumber(value: 0x7767_6874)   // 'wght'
    private static let wdthAxis = NSNumber(value: 0x7764_7468)   // 'wdth'
    private static var descriptors: [String: CTFontDescriptor] = [:]
    private static var cache: [String: Font] = [:]

    static func register() {
        guard let dir = Bundle.main.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "ttf" {
            let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for d in descs {
                if let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String {
                    descriptors[name] = d
                }
            }
        }
    }

    static func font(_ postScriptName: String, size: CGFloat, weight: CGFloat, width: CGFloat?) -> Font {
        let key = "\(postScriptName)|\(size)|\(weight)|\(width ?? 0)"
        if let cached = cache[key] { return cached }

        let font: Font
        if let base = descriptors[postScriptName] {
            var axes: [NSNumber: NSNumber] = [wghtAxis: NSNumber(value: Double(weight))]
            if let width { axes[wdthAxis] = NSNumber(value: Double(width)) }
            let desc = CTFontDescriptorCreateCopyWithAttributes(
                base, [kCTFontVariationAttribute: axes] as CFDictionary)
            font = Font(CTFontCreateWithFontDescriptor(desc, size, nil))
        } else {
            font = .system(size: size, weight: fallbackWeight(weight))
        }
        cache[key] = font
        return font
    }

    private static func fallbackWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}

enum BrandWeight {
    static let regular: CGFloat = 400
    static let medium: CGFloat = 500
    static let semibold: CGFloat = 600
    static let bold: CGFloat = 700
    static let extraBold: CGFloat = 800
}

extension Font {
    /// Markanın fontu. `width`: 75 (dar) – 100 (normal) – 125 (geniş; font desteklediği kadar)
    static func brand(_ size: CGFloat, _ weight: CGFloat = BrandWeight.regular, width: CGFloat = 100) -> Font {
        Typography.font(BrandConfig.fontName, size: size, weight: weight, width: width)
    }

    /// Sayılar ve format kodları için; markanın mono fontu yoksa sabit genişlikli rakamlar
    static func brandMono(_ size: CGFloat, _ weight: CGFloat = BrandWeight.regular) -> Font {
        if let mono = BrandConfig.monoFontName {
            return Typography.font(mono, size: size, weight: weight, width: nil)
        }
        return brand(size, weight).monospacedDigit()
    }
}
