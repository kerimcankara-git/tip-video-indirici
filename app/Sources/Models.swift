import Foundation

struct VideoInfo: Decodable {
    let id: String
    let title: String?
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let formats: [VideoFormat]?
    let extractor_key: String?
    /// Birden fazla video içeren gönderiler (ör. tweet, Instagram carousel) liste olarak gelir
    let entries: [VideoInfo]?

    /// Liste ise seçenekler için ilk video kullanılır
    var primary: VideoInfo { entries?.first(where: { !($0.formats ?? []).isEmpty }) ?? self }
    var videoCount: Int { entries?.count ?? 1 }

    var displayTitle: String { title ?? primary.title ?? id }
    var displayThumbnail: String? { thumbnail ?? primary.thumbnail }
    var displayDuration: Double? { duration ?? primary.duration }

    var platform: String? {
        switch extractor_key ?? primary.extractor_key {
        case "Youtube": return "YouTube"
        case "Twitter": return "X (Twitter)"
        case "Instagram", "InstagramStory", "InstagramIOS": return "Instagram"
        case let key?: return key
        default: return nil
        }
    }

    var usableFormats: [VideoFormat] {
        (primary.formats ?? []).filter { $0.ext != "mhtml" && $0.format_note != "storyboard" && ($0.hasVideo || $0.hasAudio) }
    }

    var heights: [Int] {
        Array(Set(usableFormats.filter(\.hasVideo).compactMap(\.height))).sorted(by: >)
    }
}

struct VideoFormat: Decodable, Identifiable, Hashable {
    let format_id: String
    let ext: String?
    let height: Int?
    let fps: Double?
    let vcodec: String?
    let acodec: String?
    let abr: Double?
    let filesize: Double?
    let filesize_approx: Double?
    let format_note: String?

    var id: String { format_id }
    var hasVideo: Bool { vcodec != nil && vcodec != "none" }
    var hasAudio: Bool { acodec != nil && acodec != "none" }
    var size: Double? { filesize ?? filesize_approx }

    var kind: String { hasVideo && hasAudio ? "Video+Ses" : hasVideo ? "Video" : "Ses" }

    var resolution: String {
        if let height, hasVideo {
            return "\(height)p" + (fps.map { " \(Int($0))fps" } ?? "")
        }
        return abr.map { "\(Int($0)) kbps" } ?? "—"
    }

    var codecs: String {
        [hasVideo ? vcodec : nil, hasAudio ? acodec : nil]
            .compactMap { $0?.split(separator: ".").first.map(String.init) }
            .joined(separator: " / ")
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case video, audio, custom
    var id: Self { self }
    var title: String { ["video": "Video", "audio": "Sadece Ses", "custom": "Gelişmiş"][rawValue]! }
    var icon: String { ["video": "film", "audio": "waveform", "custom": "slider.horizontal.3"][rawValue]! }
}

struct DownloadRequest {
    var url: String
    var mode: Mode
    var height: Int?              // nil = en iyi
    var container = "mp4"
    var audioFormat = "mp3"
    var audioQuality = 192
    var format: VideoFormat?
    var cookiesBrowser: String?   // giriş gerektiren içerikler için tarayıcı oturumu

    var summary: String {
        switch mode {
        case .video: return "\(height.map(qualityLabel) ?? "En iyi") · \(container.uppercased())"
        case .audio:
            return audioFormat.uppercased() + (lossless(audioFormat) ? "" : " · \(audioQuality) kbps")
        case .custom: return "Format \(format?.format_id ?? "?") · \(format?.resolution ?? "")"
        }
    }
}

func qualityLabel(_ h: Int) -> String {
    switch h {
    case 4320...: return "8K"
    case 2160...: return "4K"
    case 1440...: return "2K"
    default: return "\(h)p"
    }
}

func lossless(_ format: String) -> Bool { ["wav", "flac"].contains(format) }

func formatBytes(_ b: Double?) -> String {
    guard let b, b > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

func formatDuration(_ s: Double?) -> String {
    guard let s, s.isFinite, s >= 0 else { return "" }
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}
