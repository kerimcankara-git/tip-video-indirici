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
        var args = [
            "--no-playlist", "--no-warnings", "--newline", "--progress", "--no-simulate", "--no-mtime",
            "--js-runtimes", "deno:\(Tools.deno.path)",
            "--ffmpeg-location", Tools.ffmpeg.path,
            // Tweet metinleri uzun olabiliyor; dosya adı sınırını aşmasın
            "-P", dir.path, "-o", outputTemplate(req.clip),
            "--progress-template", "download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:[PP]%(progress.postprocessor)s",
            "--print", "after_move:[F]%(filepath)s",
            "--print", "after_move:[C]%(vcodec)s|%(acodec)s|%(duration)s",
        ]

        switch req.mode {
        case .video:
            let h = req.height.map { "[height<=\($0)]" } ?? ""
            args += ["-f", "bv*\(h)+ba/b\(h)/b", "--merge-output-format", req.container]
            switch req.container {
            // Aynı çözünürlükte H.264 + AAC tercih edilir; 1080p üstü sonradan HEVC'ye çevrilir
            case "mp4": args += ["-S", "res,vcodec:h264,acodec:aac"]
            case "webm": args += ["-S", "res,vcodec:vp9,acodec:opus"]
            default: break
            }
        case .audio:
            args += ["-f", "bestaudio/best", "-x", "--audio-format", req.audioFormat]
            if !lossless(req.audioFormat) { args += ["--audio-quality", "\(req.audioQuality)K"] }
        case .custom:
            guard let f = req.format else { return }
            args += ["-f", f.hasVideo && !f.hasAudio ? "\(f.format_id)+bestaudio" : f.format_id]
        }
        if let clip = req.clip {
            // Sadece seçilen aralık indirilir; kesimler tam saniyeden olsun diye uçlar yeniden kodlanır
            args += ["--download-sections", "*\(clip.lowerBound)-\(clip.upperBound)", "--force-keyframes-at-cuts"]
        }
        args += cookieArgs(req.cookiesBrowser)
        args.append(req.url)

        var outputs: [Output] = []
        let result: Runner.Result
        do {
            result = try await Runner.run(Tools.ytdlp, args, started: { job.process = $0 }) { line in
                handle(line, job: job, outputs: &outputs)
            }
        } catch {
            return fail(job, error.localizedDescription)
        }

        if job.cancelled { return finishCancelled(job) }
        guard result.status == 0, job.fileURL != nil else {
            return fail(job, result.errorMessage ?? "İndirme başarısız")
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

    private struct Output {
        let url: URL
        var video = "", audio = "", duration: Double = 0
    }

    /// Kesilen parçalarda aralık dosya adına eklenir: "Başlık [id] (1.23-2.45).mp4"
    private static func outputTemplate(_ clip: ClosedRange<Double>?) -> String {
        guard let clip else { return "%(title).120B [%(id)s].%(ext)s" }
        let label = [clip.lowerBound, clip.upperBound].map { formatClock($0).replacingOccurrences(of: ":", with: ".") }
        return "%(title).100B [%(id)s] (\(label[0])-\(label[1])).%(ext)s"
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
    private static func handle(_ line: String, job: DownloadJob, outputs: inout [Output]) {
        if line.hasPrefix("[P]") {
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
