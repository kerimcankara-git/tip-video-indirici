import Foundation

/// Uygulamanın içinde gelen yt-dlp, ffmpeg ve deno.
/// yt-dlp kendini güncelleyebilsin diye Application Support'a kopyalanıp oradan çalıştırılır.
enum Tools {
    static let bundled = Bundle.main.resourceURL!.appendingPathComponent("bin")
    static let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(BrandConfig.supportFolder)/bin")

    static var ytdlp: URL { support.appendingPathComponent("yt-dlp") }
    static var ffmpeg: URL { bundled.appendingPathComponent("ffmpeg") }
    static var deno: URL { bundled.appendingPathComponent("deno") }
    private static var versionFile: URL { support.appendingPathComponent("yt-dlp.version") }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [support.path, bundled.path, "/usr/bin", "/bin"].joined(separator: ":")
        // Gömülü ffmpeg başka bir makinede derlendiği için güvenilir sertifika listesini bulamıyor;
        // kesit indirirken (ffmpeg doğrudan siteye bağlanır) "certificate verify failed" hatası verir.
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        return env
    }

    /// İlk açılışta ya da uygulamayla daha yeni bir yt-dlp geldiğinde kopyalar. Kurulu sürümü döndürür.
    static func prepare() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true)

        let bundledVersion = read(bundled.appendingPathComponent("yt-dlp.version"))
        let installedVersion = read(versionFile)
        if !fm.fileExists(atPath: ytdlp.path) || bundledVersion > installedVersion {
            try? fm.removeItem(at: ytdlp)
            try fm.copyItem(at: bundled.appendingPathComponent("yt-dlp"), to: ytdlp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytdlp.path)
            try bundledVersion.write(to: versionFile, atomically: true, encoding: .utf8)
        }
        for url in [ytdlp, ffmpeg, deno] {
            removexattr(url.path, "com.apple.quarantine", 0)
        }
        return max(bundledVersion, installedVersion)
    }

    /// yt-dlp -U ile en son sürüme günceller, yeni sürümü döndürür.
    static func update() async throws -> String {
        let result = try await Runner.run(ytdlp, ["-U"])
        let version = try await Runner.run(ytdlp, ["--version"])
        let text = String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !text.isEmpty else {
            throw AppError(result.errorMessage ?? "Güncelleme başarısız")
        }
        try text.write(to: versionFile, atomically: true, encoding: .utf8)
        return text
    }

    private static func read(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Alt süreç çalıştırıcı. Çıkış satır satır `onLine`'a gönderilir ya da toplanıp döndürülür.
enum Runner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String

        /// yt-dlp'nin "ERROR: ..." satırı, yoksa son stderr satırı
        var errorMessage: String? {
            let lines = stderr.split(separator: "\n").map(String.init)
            let line = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last
            return line?.replacingOccurrences(of: "ERROR: ", with: "")
        }
    }

    private static let lock = NSLock()
    private static var running = Set<Process>()

    static func terminateAll() {
        track { $0.forEach { $0.terminate() } }
    }

    private static func track(_ body: (inout Set<Process>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&running)
    }

    static func run(_ exe: URL, _ args: [String],
                    started: ((Process) -> Void)? = nil,
                    onLine: (@MainActor (String) -> Void)? = nil) async throws -> Result {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = Tools.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let exit = AsyncStream<Int32> { c in
            p.terminationHandler = { proc in
                track { $0.remove(proc) }
                c.yield(proc.terminationStatus)
                c.finish()
            }
        }
        try p.run()
        track { $0.insert(p) }
        started?(p)

        let errTask = Task.detached { String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        var data = Data()
        if let onLine {
            for try await line in out.fileHandleForReading.bytes.lines {
                await onLine(line)
            }
        } else {
            data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        }
        var status: Int32 = -1
        for await s in exit { status = s }
        return Result(status: status, stdout: data, stderr: await errTask.value)
    }
}
