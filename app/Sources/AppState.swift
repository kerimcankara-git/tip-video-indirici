import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Bağlantı ve video bilgisi
    @Published var urlText = ""
    @Published var info: VideoInfo?
    @Published var isFetching = false
    @Published var fetchError: String?
    @Published var fetchNeedsLogin = false

    // Seçenekler
    @Published var mode: Mode = .video
    @Published var height: Int?
    @Published var container = "mp4"
    @Published var audioFormat = "mp3"
    @Published var audioQuality = 192
    @Published var customFormat: VideoFormat?

    // Kesim: sadece seçilen aralığı indir
    @Published var clipEnabled = false
    @Published var clipStart: Double = 0
    @Published var clipEnd: Double = 0
    /// Instagram / X gibi giriş gerektiren içerikler için yt-dlp'nin çerezleri okuyacağı tarayıcı
    @Published var cookiesBrowser: String {
        didSet { UserDefaults.standard.set(cookiesBrowser, forKey: "cookiesBrowser") }
    }

    // İndirmeler
    @Published var jobs: [DownloadJob] = []
    @Published var downloadDir: URL {
        didSet { UserDefaults.standard.set(downloadDir.path, forKey: "downloadDir") }
    }

    // yt-dlp
    @Published var toolsReady = false
    @Published var ytdlpVersion = ""
    @Published var isUpdating = false
    @Published var toolMessage: String?

    @Published var showHelp = false

    private var fetchedURL = ""
    private var lastClipboard = ""
    private var badgeTimer: Timer?

    /// Çıkış korumasının (QuitGuard) süren indirmeleri görebilmesi için
    static weak var current: AppState?

    init() {
        cookiesBrowser = UserDefaults.standard.string(forKey: "cookiesBrowser") ?? ""
        let saved = UserDefaults.standard.string(forKey: "downloadDir")
        downloadDir = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BrandConfig.appName)

        Task.detached {
            do {
                let version = try Tools.prepare()
                await MainActor.run { self.ytdlpVersion = version; self.toolsReady = true }
            } catch {
                await MainActor.run { self.toolMessage = "Araçlar hazırlanamadı: \(error.localizedDescription)" }
            }
        }
        Self.current = self
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateBadge() }
        }
    }

    // MARK: Bağlantı

    func fetch() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, toolsReady, !isFetching else { return }
        isFetching = true
        fetchError = nil
        fetchNeedsLogin = false
        Task {
            do {
                let result = try await Downloader.fetchInfo(url, cookiesBrowser: cookiesBrowser)
                info = result
                fetchedURL = url
                customFormat = nil
                if let h = height, !result.heights.contains(h) { height = nil }
                clipEnabled = false
                clipStart = 0
                clipEnd = result.displayDuration ?? 0
            } catch {
                info = nil
                fetchError = error.localizedDescription
                let text = error.localizedDescription.lowercased()
                fetchNeedsLogin = ["login", "log in", "cookies", "rate-limit", "private", "sign in", "authentication"]
                    .contains { text.contains($0) }
            }
            isFetching = false
        }
    }

    func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
            fetch()
        }
    }

    /// Uygulamaya dönüldüğünde panoda desteklenen yeni bir bağlantı varsa otomatik getirir.
    func checkClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              s != lastClipboard else { return }
        lastClipboard = s
        guard isSupportedURL(s), s != fetchedURL, !isFetching else { return }
        urlText = s
        fetch()
    }

    func clear() {
        urlText = ""
        info = nil
        fetchError = nil
        fetchNeedsLogin = false
        fetchedURL = ""
    }

    // MARK: İndirme

    var canDownload: Bool {
        info != nil && (mode != .custom || customFormat != nil) && (!clipEnabled || clipEnd - clipStart >= 0.5)
    }

    /// Kesim yalnızca süresi bilinen, tek videolu içeriklerde sunulur (canlı yayın / çok videolu gönderi hariç)
    var clipAvailable: Bool {
        guard let info else { return false }
        return info.videoCount == 1 && (info.displayDuration ?? 0) >= 2
    }

    var willConvert: Bool {
        guard mode == .video, container == "mp4", let info else { return false }
        return (height ?? info.heights.first ?? 0) > 1080
    }

    func startDownload() {
        guard let info, canDownload else { return }
        var req = DownloadRequest(url: fetchedURL, mode: mode, height: height)
        req.container = container
        req.audioFormat = audioFormat
        req.audioQuality = audioQuality
        req.format = customFormat
        req.cookiesBrowser = cookiesBrowser
        if clipEnabled, clipAvailable { req.clip = clipStart...clipEnd }

        var summary = req.summary
        if let clip = req.clip { summary += " · ✂︎ \(formatClock(clip.lowerBound))–\(formatClock(clip.upperBound))" }
        if info.videoCount > 1 { summary += " · \(info.videoCount) video" }
        let job = DownloadJob(title: info.displayTitle, thumbnail: info.displayThumbnail.flatMap(URL.init(string:)),
                              summary: summary)
        jobs.insert(job, at: 0)
        let dir = downloadDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { await Downloader.download(job, req, to: dir) }
    }

    func remove(_ job: DownloadJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Seç"
        panel.directoryURL = downloadDir
        if panel.runModal() == .OK, let url = panel.url { downloadDir = url }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloadDir)
    }

    // MARK: yt-dlp güncelleme

    func updateTools() {
        guard !isUpdating else { return }
        isUpdating = true
        toolMessage = nil
        Task {
            do {
                let new = try await Tools.update()
                toolMessage = new == ytdlpVersion ? "yt-dlp zaten güncel" : "yt-dlp \(new) sürümüne güncellendi"
                ytdlpVersion = new
            } catch {
                toolMessage = error.localizedDescription
            }
            isUpdating = false
        }
    }

    private func updateBadge() {
        let active = jobs.filter(\.isActive).count
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
    }
}

/// Pano algılaması için desteklenen siteler (yt-dlp çok daha fazlasını destekler; elle yapıştırılan her bağlantı denenir)
func isSupportedURL(_ s: String) -> Bool {
    guard let host = URL(string: s)?.host?.lowercased() else { return false }
    let domains = ["youtube.com", "youtu.be", "youtube-nocookie.com", "twitter.com", "x.com", "instagram.com"]
    return domains.contains { host == $0 || host.hasSuffix("." + $0) }
}

/// yt-dlp'nin çerez okuyabildiği tarayıcılar (değer, görünen ad)
let cookieBrowsers: [(String, String)] = [
    ("", "Oturum kullanma"), ("chrome", "Chrome"), ("safari", "Safari"), ("firefox", "Firefox"),
    ("brave", "Brave"), ("edge", "Edge"), ("arc", "Arc"),
]
