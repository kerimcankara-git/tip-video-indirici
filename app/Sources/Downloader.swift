import AppKit

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum Phase { case starting, downloading, processing, converting, done, failed, cancelled }

    let id = UUID()
    let title: String
    let thumbnail: URL?
    let summary: String

    @Published var phase: Phase = .starting
    @Published var progress: Double = 0
    @Published var detail = "Başlatılıyor…"
    @Published var fileURL: URL?
    /// Toplam boyut bilinmiyorsa (ör. bölüm indirirken) ilerleme çubuğu belirsiz gösterilir
    @Published var indeterminate = false

    fileprivate var process: Process?
    fileprivate var cancelled = false

    init(title: String, thumbnail: URL?, summary: String) {
        self.title = title
        self.thumbnail = thumbnail
        self.summary = summary
    }

    var isActive: Bool { [.starting, .downloading, .processing, .converting].contains(phase) }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func reveal() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    }

    func open() {
        if let fileURL { NSWorkspace.shared.open(fileURL) }
    }
}

enum Downloader {
    /// QuickTime / Premiere / Final Cut'ın doğrudan açtığı codec'ler
    private static let macVideo = ["avc", "h264", "hev", "hvc", "hevc"]
    private static let macAudio = ["mp4a", "aac", "mp3", "alac"]

    static func fetchInfo(_ url: String, cookiesBrowser: String?) async throws -> VideoInfo {
        let r = try await Runner.run(Tools.ytdlp, ["-J", "--no-playlist", "--no-warnings",
                                                   "--js-runtimes", "deno:\(Tools.deno.path)"]
                                                  + cookieArgs(cookiesBrowser) + [url])
        guard r.status == 0 else { throw AppError(r.errorMessage ?? "Video bilgileri alınamadı") }
        return try JSONDecoder().decode(VideoInfo.self, from: r.stdout)
    }

    @MainActor
    static func download(_ job: DownloadJob, _ req: DownloadRequest, to dir: URL) async {
        var base = [
            "--no-playlist", "--no-warnings", "--newline", "--progress", "--no-simulate", "--no-mtime",
            "--js-runtimes", "deno:\(Tools.deno.path)",
            "--ffmpeg-location", Tools.ffmpeg.path,
            "--progress-template", "download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:[PP]%(progress.postprocessor)s",
            "--print", "after_move:[F]%(filepath)s",
            "--print", "after_move:[C]%(vcodec)s|%(acodec)s|%(duration)s",
        ]

        switch req.mode {
        case .video:
            let h = req.height.map { "[height<=\($0)]" } ?? ""
            base += ["-f", "bv*\(h)+ba/b\(h)/b", "--merge-output-format", req.container]
            switch req.container {
            // Aynı çözünürlükte H.264 + AAC tercih edilir; 1080p üstü sonradan HEVC'ye çevrilir
            case "mp4": base += ["-S", "res,vcodec:h264,acodec:aac"]
            case "webm": base += ["-S", "res,vcodec:vp9,acodec:opus"]
            default: break
            }
        case .audio:
            base += ["-f", "bestaudio/best", "-x", "--audio-format", req.audioFormat]
            if !lossless(req.audioFormat) { base += ["--audio-quality", "\(req.audioQuality)K"] }
        case .custom:
            guard let f = req.format else { return }
            base += ["-f", f.hasVideo && !f.hasAudio ? "\(f.format_id)+bestaudio" : f.format_id]
        }
        let site = cookieArgs(req.cookiesBrowser) + [req.url]

        var outputs: [Output]
        if let clip = req.clip {
            var section: SectionResult = .fallback
            if !req.localCut {
                section = await downloadSection(job, base: base, site: site, clip: clip, to: dir)
            }
            if job.cancelled { return finishCancelled(job) }
            switch section {
            case .ok(let result): outputs = result
            case .failed: return
            case .fallback:
                guard let result = await downloadAndCut(job, req, base: base, site: site, clip: clip, to: dir) else {
                    if job.cancelled { finishCancelled(job) }
                    return
                }
                outputs = result
            }
        } else {
            // Tweet metinleri uzun olabiliyor; dosya adı sınırını aşmasın
            let args = base + ["-P", dir.path, "-o", "%(title).120B [%(id)s].%(ext)s"] + site
            let (result, out) = await runYtdlp(job, args, clipLength: nil)
            if job.cancelled { return finishCancelled(job) }
            guard let result else { return }
            guard result.status == 0, !out.isEmpty else {
                return fail(job, result.errorMessage ?? "İndirme başarısız")
            }
            outputs = out
        }

        if req.mode == .video, req.container == "mp4" {
            for (i, out) in outputs.enumerated() {
                // Dosyanın gerçek codec'ine bakılır (kesilen parçalar yeniden kodlanmış olabilir)
                let probed = await probe(out.url)
                let video = probed.video ?? out.video, audio = probed.audio ?? out.audio
                let needsVideo = !video.isEmpty && video != "none" && !macVideo.contains { video.hasPrefix($0) }
                let needsAudio = !audio.isEmpty && audio != "none" && !macAudio.contains { audio.hasPrefix($0) }
                guard needsVideo || needsAudio else { continue }
                let label = outputs.count > 1 ? " (\(i + 1)/\(outputs.count))" : ""
                await convert(job, out.url, video: needsVideo, audio: needsAudio, duration: out.duration, label: label)
                if job.phase != .converting { return }
            }
        }

        job.phase = .done
        job.progress = 1
        let size = outputs.compactMap { try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        job.detail = (outputs.count > 1 ? "\(outputs.count) video · " : "Tamamlandı · ") + formatBytes(Double(size))
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// yt-dlp'yi çalıştırır; çıktı satırlarını işler. Başlatılamazsa işi başarısız sayar ve sonucu nil döndürür.
    @MainActor
    private static func runYtdlp(_ job: DownloadJob, _ args: [String], clipLength: Double?) async -> (Runner.Result?, [Output]) {
        var outputs: [Output] = []
        do {
            let result = try await Runner.run(Tools.ytdlp, args, started: { job.process = $0 }) { line in
                handle(line, job: job, outputs: &outputs, clipLength: clipLength)
            }
            return (result, outputs)
        } catch {
            fail(job, error.localizedDescription)
            return (nil, [])
        }
    }

    private enum SectionResult {
        case ok([Output])
        case fallback   // "tam indir + bilgisayarda kes" yoluna geç
        case failed     // hata gösterildi
    }

    /// Sadece seçilen aralığı indirir (yt-dlp --download-sections; siteye ffmpeg bağlanır).
    @MainActor
    private static func downloadSection(_ job: DownloadJob, base: [String], site: [String],
                                        clip: ClosedRange<Double>, to dir: URL) async -> SectionResult {
        // Kesimler tam saniyeden olsun diye uçlar yeniden kodlanır. Bu indirmeyi ffmpeg yapar ve yt-dlp'ye
        // ilerleme bildirmez; ilerlemeyi ffmpeg'in kendisinden okuruz.
        let args = base + ["-P", dir.path, "-o", clipTemplate(clip),
                           "--download-sections", "*\(clip.lowerBound)-\(clip.upperBound)", "--force-keyframes-at-cuts",
                           "--downloader-args", "ffmpeg:-progress pipe:1 -nostats"] + site
        job.indeterminate = true
        job.detail = "Kesit hazırlanıyor…"

        // YouTube bazı istemcilerin adreslerinde ffmpeg'in bağlantısını zaman zaman reddediyor
        // (403 → "ffmpeg exited with code 8"). Her denemede yt-dlp yeni adresler aldığı için yeniden denenir.
        let attempts = 3
        for attempt in 1...attempts {
            let (result, outputs) = await runYtdlp(job, args, clipLength: clip.upperBound - clip.lowerBound)
            if job.cancelled { return .failed }
            guard let result else { return .failed }
            if result.status == 0, !outputs.isEmpty {
                // Bazı akış türlerinde (ör. yalnızca DASH parçaları) yt-dlp başarılı dönüp boş dosya üretiyor
                let tiny = outputs.contains { ((try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 16_384 }
                guard tiny else { return .ok(outputs) }
                outputs.forEach { try? FileManager.default.removeItem(at: $0.url) }
                return .fallback
            }
            let refused = result.stderr.contains("ffmpeg exited with code") || result.stderr.contains("403")
            guard refused else {
                fail(job, result.errorMessage ?? "İndirme başarısız")
                return .failed
            }
            if attempt < attempts {
                job.phase = .downloading
                job.indeterminate = true
                job.progress = 0
                job.detail = "Bağlantı reddedildi, yeniden deneniyor (\(attempt + 1)/\(attempts))…"
            }
        }
        return .fallback
    }

    /// Yedek yol: videoyu yt-dlp'nin kendi yöntemiyle tam indirir (geçici klasöre), aralığı bilgisayarda
    /// ffmpeg ile keser ve tam dosyayı siler. Daha yavaş ama akış türünden ve bağlantı reddinden etkilenmez.
    @MainActor
    private static func downloadAndCut(_ job: DownloadJob, _ req: DownloadRequest, base: [String], site: [String],
                                       clip: ClosedRange<Double>, to dir: URL) async -> [Output]? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kesit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        job.phase = .downloading
        job.indeterminate = true
        job.progress = 0
        job.detail = "Tam video indiriliyor (kesit için)…"
        let args = base + ["-P", tmp.path, "-o", "%(title).100B [%(id)s].%(ext)s"] + site
        let (result, full) = await runYtdlp(job, args, clipLength: nil)
        if job.cancelled { return nil }
        guard let result else { return nil }
        guard result.status == 0, !full.isEmpty else {
            fail(job, result.errorMessage ?? "İndirme başarısız")
            return nil
        }

        let length = clip.upperBound - clip.lowerBound
        var outputs: [Output] = []
        for src in full {
            let ext = src.url.pathExtension.lowercased()
            let codec = cutCodecArgs(ext: ext, quality: req.mode == .audio ? req.audioQuality : 192)
            let dest = dir.appendingPathComponent(src.url.deletingPathExtension().lastPathComponent
                                                  + " (\(clipLabel(clip))).\(codec.ext)")
            job.phase = .converting
            job.indeterminate = false
            job.progress = 0
            job.detail = "Kesiliyor…"
            let cutArgs = ["-y", "-v", "error", "-ss", "\(clip.lowerBound)", "-i", src.url.path, "-t", "\(length)",
                           "-map", "0:v:0?", "-map", "0:a:0?"] + codec.args + ["-progress", "pipe:1", "-nostats", dest.path]
            do {
                let r = try await Runner.run(Tools.ffmpeg, cutArgs, started: { job.process = $0 }) { line in
                    guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                    job.progress = min(0.999, max(0, us / 1e6 / length))
                    job.detail = "Kesiliyor… %\(Int(job.progress * 100))"
                }
                if job.cancelled { try? FileManager.default.removeItem(at: dest); return nil }
                guard r.status == 0 else {
                    try? FileManager.default.removeItem(at: dest)
                    fail(job, "Kesme başarısız: " + (r.stderr.split(separator: "\n").last.map(String.init) ?? ""))
                    return nil
                }
            } catch {
                fail(job, error.localizedDescription)
                return nil
            }
            job.fileURL = dest
            outputs.append(Output(url: dest, video: src.video, audio: src.audio, duration: length))
        }
        return outputs
    }

    /// Bilgisayarda kesimde kullanılacak kodlayıcılar (çıktı uzantısına göre); kesim tam saniyeden olsun diye yeniden kodlanır
    private static func cutCodecArgs(ext: String, quality: Int) -> (ext: String, args: [String]) {
        let h264 = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        switch ext {
        case "mp4", "m4v", "mov": return (ext, h264 + ["-movflags", "+faststart"])
        case "mkv": return (ext, h264)
        case "webm":
            return (ext, ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "0", "-crf", "32",
                          "-c:a", "libopus", "-b:a", "128k"])
        case "mp3": return (ext, ["-vn", "-c:a", "libmp3lame", "-b:a", "\(quality)k"])
        case "m4a", "aac": return (ext, ["-vn", "-c:a", "aac", "-b:a", "\(quality)k"])
        case "wav": return (ext, ["-vn", "-c:a", "pcm_s16le"])
        case "flac": return (ext, ["-vn", "-c:a", "flac"])
        case "opus", "ogg": return (ext, ["-vn", "-c:a", "libopus", "-b:a", "\(quality)k"])
        default: return ("mp4", h264 + ["-movflags", "+faststart"])
        }
    }

    private struct Output {
        let url: URL
        var video = "", audio = "", duration: Double = 0
    }

    /// Kesilen parçalarda aralık dosya adına eklenir: "Başlık [id] (1.23-2.45).mp4"
    private static func clipLabel(_ clip: ClosedRange<Double>) -> String {
        [clip.lowerBound, clip.upperBound].map { formatClock($0).replacingOccurrences(of: ":", with: ".") }
            .joined(separator: "-")
    }

    private static func clipTemplate(_ clip: ClosedRange<Double>) -> String {
        "%(title).100B [%(id)s] (\(clipLabel(clip))).%(ext)s"
    }

    /// ffmpeg ile dosyadaki video ve ses codec'lerini okur (ör. "h264", "av1", "opus")
    private static func probe(_ url: URL) async -> (video: String?, audio: String?) {
        guard let r = try? await Runner.run(Tools.ffmpeg, ["-hide_banner", "-i", url.path]) else { return (nil, nil) }
        func codec(_ kind: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: "Stream #[^\\n]*?: \(kind): ([A-Za-z0-9_]+)"),
                  let m = re.firstMatch(in: r.stderr, range: NSRange(r.stderr.startIndex..., in: r.stderr)),
                  let range = Range(m.range(at: 1), in: r.stderr) else { return nil }
            return String(r.stderr[range])
        }
        return (codec("Video"), codec("Audio"))
    }

    private static func cookieArgs(_ browser: String?) -> [String] {
        guard let browser, !browser.isEmpty else { return [] }
        return ["--cookies-from-browser", browser]
    }

    @MainActor
    private static func handle(_ line: String, job: DownloadJob, outputs: inout [Output], clipLength: Double?) {
        if line.hasPrefix("out_time_us="), let clipLength, clipLength > 0 {
            // Kesit indirirken ffmpeg'in ilerlemesi (-progress pipe:1)
            guard let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            job.phase = .downloading
            job.indeterminate = false
            job.progress = min(0.999, max(0, us / 1e6 / clipLength))
            job.detail = "Kesit indiriliyor… %\(Int(job.progress * 100))"
        } else if line.hasPrefix("[P]") {
            let p = line.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false).map { Double($0) }
            guard p.count == 5, let done = p[0] else { return }
            let total = p[1] ?? p[2]
            job.phase = .downloading
            var parts: [String]
            if let total, total > 0 {
                job.indeterminate = false
                job.progress = min(1, done / total)
                parts = ["%\(Int(job.progress * 100))"]
            } else {
                job.indeterminate = true
                parts = [formatBytes(done)]
            }
            if let speed = p[3] { parts.append(formatBytes(speed) + "/sn") }
            if let eta = p[4] { parts.append(formatDuration(eta) + " kaldı") }
            job.detail = parts.joined(separator: " · ")
        } else if line.hasPrefix("[PP]") {
            job.phase = .processing
            job.indeterminate = false
            let names = ["Merger": "Video ve ses birleştiriliyor…", "ExtractAudio": "Ses dönüştürülüyor…"]
            job.detail = names[String(line.dropFirst(4))] ?? "İşleniyor…"
        } else if line.hasPrefix("[F]") {
            let url = URL(fileURLWithPath: String(line.dropFirst(3)))
            outputs.append(Output(url: url))
            job.fileURL = url
        } else if line.hasPrefix("[C]"), !outputs.isEmpty {
            let c = line.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if c.count == 3 {
                outputs[outputs.count - 1].video = c[0]
                outputs[outputs.count - 1].audio = c[1]
                outputs[outputs.count - 1].duration = Double(c[2]) ?? 0
            }
        }
    }

    /// AV1/VP9'u donanım kodlayıcıyla HEVC'ye, Opus'u AAC'ye çevirir.
    @MainActor
    private static func convert(_ job: DownloadJob, _ src: URL, video: Bool, audio: Bool,
                                duration: Double, label: String) async {
        let tmp = src.deletingPathExtension().appendingPathExtension("converting.mp4")
        job.phase = .converting
        job.indeterminate = false
        job.progress = 0
        job.detail = "Mac uyumlu formata dönüştürülüyor\(label)…"

        var args = ["-y", "-v", "error", "-i", src.path, "-map", "0:v:0?", "-map", "0:a:0?"]
        args += video ? ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"] : ["-c:v", "copy"]
        args += audio ? ["-c:a", "aac", "-b:a", "192k"] : ["-c:a", "copy"]
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", tmp.path]

        do {
            let r = try await Runner.run(Tools.ffmpeg, args, started: { job.process = $0 }) { line in
                guard line.hasPrefix("out_time_us="), duration > 0,
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                job.progress = min(0.999, us / 1e6 / duration)
                job.detail = "Mac uyumlu formata dönüştürülüyor\(label)… %\(Int(job.progress * 100))"
            }
            if job.cancelled {
                try? FileManager.default.removeItem(at: tmp)
                return finishCancelled(job)
            }
            guard r.status == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return fail(job, "Dönüştürme başarısız: " + (r.stderr.split(separator: "\n").last.map(String.init) ?? ""))
            }
            _ = try FileManager.default.replaceItemAt(src, withItemAt: tmp)
        } catch {
            fail(job, error.localizedDescription)
        }
    }

    @MainActor private static func fail(_ job: DownloadJob, _ message: String) {
        job.phase = .failed
        job.detail = message
    }

    @MainActor private static func finishCancelled(_ job: DownloadJob) {
        job.phase = .cancelled
        job.detail = "İptal edildi"
    }
}
