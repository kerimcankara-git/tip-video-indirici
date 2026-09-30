import AVKit
import SwiftUI

/// Kesim önizlemesi için oynatıcı: aralığı oynatırken bitişte durur.
/// Önizleme akışında ses yoksa (YouTube'da sık), ses ayrıca hazırlanıp ikinci bir oynatıcıda eş zamanlı çalınır.
@MainActor
final class ClipPlayer: ObservableObject {
    enum AudioState { case none, preparing, ready, failed }
    /// Doğrudan oynatılabilir akış yoksa indirilen düşük kaliteli yerel kopya (ilerleme 0...1, bilinmiyorsa nil)
    enum LocalPreview: Equatable { case none, preparing(Double?), ready, failed }

    let player = AVPlayer()
    private let audioPlayer = AVPlayer()
    @Published var current: Double = 0
    @Published var isPlaying = false
    @Published var failed = false
    @Published var audioState: AudioState = .none
    @Published var localPreview: LocalPreview = .none

    private var stopAt: Double?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var loadedURL: URL?
    private var audioProcess: Process?
    private var tempDir: URL?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds.isFinite ? time.seconds : 0
                if let stop = self.stopAt, self.current >= stop { self.pause(); self.seek(stop) }
                self.keepAudioInSync()
            }
        }
    }

    deinit {
        audioProcess?.terminate()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func load(_ url: URL, headers: [String: String]) {
        guard url != loadedURL else { return }
        loadedURL = url
        failed = false
        resetAudio()
        // Bazı siteler (ör. YouTube) akışa yalnızca yt-dlp'nin kullandığı başlıklarla izin verir
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { self?.failed = item.status == .failed }
        }
        player.replaceCurrentItem(with: item)
        // Bazı akışlar ne açılır ne hata verir; 10 sn içinde hazır olmazsa "önizleme açılamadı"ya geç
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item, item.status != .readyToPlay else { return }
            self.failed = true
        }
    }

    // MARK: Yerel önizleme

    /// Doğrudan oynatılabilir akışı olmayan videolar (ör. yeni bitmiş canlı yayınlar, yalnızca DASH) için en düşük
    /// kaliteli, sesli bir kopyayı geçici klasöre indirip oynatır.
    func loadLocalPreview(pageURL: String, cookiesBrowser: String?) {
        guard localPreview == .none else { return }
        resetAudio()
        localPreview = .preparing(nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onizleme-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        var args = ["--no-warnings", "--newline", "--progress", "--no-playlist",
                    "-f", "wv*[vcodec^=avc1]+wa[acodec^=mp4a]/wv*+wa/w", "--merge-output-format", "mp4",
                    "--progress-template", "download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
                    "--js-runtimes", "deno:\(Tools.deno.path)", "--ffmpeg-location", Tools.ffmpeg.path,
                    "-o", dir.appendingPathComponent("onizleme.%(ext)s").path]
        if let cookiesBrowser, !cookiesBrowser.isEmpty { args += ["--cookies-from-browser", cookiesBrowser] }
        args.append(pageURL)
        Task { [weak self] in
            let result = try? await Runner.run(Tools.ytdlp, args, started: { p in self?.audioProcess = p }) { line in
                guard let self, self.tempDir == dir, line.hasPrefix("[P]") else { return }
                let p = line.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false).map { Double($0) }
                guard p.count == 3, let done = p[0], let total = p[1] ?? p[2], total > 0 else { return }
                self.localPreview = .preparing(min(1, done / total))
            }
            guard let self, self.tempDir == dir else { return }   // bu arada başka bir video yüklendi
            self.audioProcess = nil
            let file = dir.appendingPathComponent("onizleme.mp4")
            guard let result, result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
                self.localPreview = .failed
                return
            }
            self.failed = false
            self.loadedURL = file
            self.player.replaceCurrentItem(with: AVPlayerItem(url: file))
            self.localPreview = .ready
        }
    }

    // MARK: Ayrı ses

    /// Videonun sesini en düşük kalitede m4a olarak geçici bir klasöre indirir. YouTube'un ses akışlarına doğrudan
    /// bağlanılamıyor (AVPlayer açamıyor, tek istekte 403); bu yüzden gerçek indirmelerle aynı yol (yt-dlp) kullanılır.
    /// Normal uzunluktaki videolarda birkaç saniye sürer; bu sırada görüntü sessiz oynar.
    func loadAudio(pageURL: String, cookiesBrowser: String?) {
        guard audioState == .none else { return }
        audioState = .preparing
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onizleme-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        var args = ["--no-warnings", "--quiet", "--no-playlist", "-f", "wa[acodec^=mp4a]/wa", "-x", "--audio-format", "m4a",
                    "--js-runtimes", "deno:\(Tools.deno.path)", "--ffmpeg-location", Tools.ffmpeg.path,
                    "-o", dir.appendingPathComponent("ses.%(ext)s").path]
        if let cookiesBrowser, !cookiesBrowser.isEmpty { args += ["--cookies-from-browser", cookiesBrowser] }
        args.append(pageURL)
        Task { [weak self] in
            let result = try? await Runner.run(Tools.ytdlp, args, started: { p in self?.audioProcess = p })
            guard let self, self.tempDir == dir else { return }   // bu arada başka bir video yüklendi
            self.audioProcess = nil
            let file = dir.appendingPathComponent("ses.m4a")
            guard let result, result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
                self.audioState = .failed
                return
            }
            self.audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: file))
            self.audioState = .ready
            self.syncAudio(force: true)
        }
    }

    private func resetAudio() {
        audioProcess?.terminate()
        audioProcess = nil
        audioPlayer.replaceCurrentItem(with: nil)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        audioState = .none
    }

    /// Sesi görüntünün konumuna ve oynatma durumuna getirir
    private func syncAudio(force: Bool = false) {
        guard audioState == .ready else { return }
        let t = player.currentTime().seconds
        if force || abs(audioPlayer.currentTime().seconds - t) > 0.25, t.isFinite {
            audioPlayer.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying { audioPlayer.play() } else { audioPlayer.pause() }
    }

    /// Oynarken ses görüntüden 0,25 sn'den fazla kayarsa yeniden hizalar
    private func keepAudioInSync() {
        guard audioState == .ready, isPlaying, player.rate > 0 else { return }
        if abs(audioPlayer.currentTime().seconds - player.currentTime().seconds) > 0.25 { syncAudio(force: true) }
    }

    // MARK: Oynatma

    func seek(_ t: Double) {
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if audioState == .ready {
            audioPlayer.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func play(until end: Double? = nil) {
        stopAt = end
        player.play()
        isPlaying = true
        syncAudio(force: true)
    }

    func pause() {
        player.pause()
        audioPlayer.pause()
        isPlaying = false
        stopAt = nil
    }

    func playRange(_ start: Double, _ end: Double) {
        seek(start)
        play(until: end)
    }
}

private struct BadgeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.brand(11, BrandWeight.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

/// "Sadece bir kısmını indir" kartı
struct ClipCard: View {
    @EnvironmentObject var state: AppState
    let info: VideoInfo
    @StateObject private var clip = ClipPlayer()

    private var duration: Double { info.displayDuration ?? 0 }
    private var preview: VideoFormat? { info.previewFormat }

    private var canPlay: Bool {
        clip.localPreview == .ready || (preview != nil && !clip.failed && clip.localPreview == .none)
    }

    private var playerBox: some View {
        ZStack {
            Color.black
            PlayerView(player: clip.player)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(formatClock(clip.current))
                .font(.brandMono(11, BrandWeight.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                .padding(8)
        }
        .overlay(alignment: .topTrailing) { audioBadge }
    }

    /// Yerel önizleme kopyası indirilirken gösterilir
    private var preparingBox: some View {
        let progress: Double? = { if case .preparing(let p) = clip.localPreview { return p } else { return nil } }()
        return VStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress).tint(Brand.accent).frame(maxWidth: 220)
                Text("Önizleme hazırlanıyor… %\(Int(progress * 100))")
            } else {
                ProgressView().controlSize(.small)
                Text("Önizleme hazırlanıyor…")
            }
            Text("Bu video doğrudan oynatılamıyor; düşük kaliteli bir kopyası indiriliyor.")
                .font(.brand(11)).foregroundStyle(.secondary)
        }
        .font(.brand(12.5, BrandWeight.medium))
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxHeight: 300)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// Ses ayrı hazırlanıyorsa görüntünün köşesinde durumunu gösterir
    @ViewBuilder private var audioBadge: some View {
        switch clip.audioState {
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Ses hazırlanıyor…")
            }
            .modifier(BadgeStyle())
        case .failed:
            Label("Ses açılamadı", systemImage: "speaker.slash.fill").modifier(BadgeStyle())
        default:
            EmptyView()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $state.clipEnabled.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Sadece bir kısmını indir", systemImage: "scissors")
                        .font(.brand(14, BrandWeight.bold))
                    Text("Başlangıç ve bitişi seç; yalnızca o aralık indirilir.")
                        .font(.brand(11.5)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Brand.accent)

            if state.clipEnabled {
                if let preview, let url = preview.url.flatMap(URL.init(string:)), !clip.failed, clip.localPreview == .none {
                    // Doğrudan akış
                    playerBox
                        .onAppear {
                            clip.load(url, headers: preview.http_headers ?? [:])
                            if info.previewNeedsAudio {
                                clip.loadAudio(pageURL: state.fetchedURL, cookiesBrowser: state.cookiesBrowser)
                            }
                            clip.seek(state.clipStart)
                        }
                        .onDisappear { clip.pause() }
                } else if clip.localPreview == .ready {
                    playerBox.onDisappear { clip.pause() }
                } else if clip.localPreview != .failed {
                    // Doğrudan oynatılabilir akış yok ya da açılmadı: düşük kaliteli sesli bir kopya hazırlanır
                    preparingBox
                        .onAppear { clip.loadLocalPreview(pageURL: state.fetchedURL, cookiesBrowser: state.cookiesBrowser) }
                } else {
                    Hint(icon: "eye.slash", text: "Bu video için önizleme açılamadı. Başlangıç ve bitişi zaman olarak yazabilirsin.")
                }

                Timeline(duration: duration, start: $state.clipStart, end: $state.clipEnd, current: clip.current) { t in
                    clip.pause()
                    clip.seek(t)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TimeField(label: "Başlangıç", value: $state.clipStart, range: 0...max(0, state.clipEnd - 0.5)) {
                        clip.seek($0)
                    }
                    Button("Şu an") { state.clipStart = min(clip.current, state.clipEnd - 0.5) }
                        .buttonStyle(PillButtonStyle(filled: false))
                        .help("Başlangıcı oynatıcının şu anki konumu yap")

                    Spacer(minLength: 8)

                    Button {
                        clip.isPlaying ? clip.pause() : clip.playRange(state.clipStart, state.clipEnd)
                    } label: {
                        Label(clip.isPlaying ? "Durdur" : "Seçimi oynat",
                              systemImage: clip.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(!canPlay)

                    Spacer(minLength: 8)

                    Button("Şu an") { state.clipEnd = max(clip.current, state.clipStart + 0.5) }
                        .buttonStyle(PillButtonStyle(filled: false))
                        .help("Bitişi oynatıcının şu anki konumu yap")
                    TimeField(label: "Bitiş", value: $state.clipEnd, range: min(duration, state.clipStart + 0.5)...duration) {
                        clip.seek($0)
                    }
                }

                Text("Seçilen: **\(formatClock(state.clipEnd - state.clipStart))**  (\(formatClock(state.clipStart)) – \(formatClock(state.clipEnd)))")
                    .font(.brand(12))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .onChange(of: info.id) { _ in clip.pause() }
        .onChange(of: clip.localPreview) { value in if value == .ready { clip.seek(state.clipStart) } }
    }
}

/// Başlangıç ve bitiş tutamaçlı zaman çizelgesi; boş yere tıklayınca oynatıcı oraya gider.
private struct Timeline: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let current: Double
    let onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (t: Double) in CGFloat(duration > 0 ? t / duration : 0) * w }
            let time = { (px: CGFloat) in min(max(Double(px / max(w, 1)) * duration, 0), duration) }

            ZStack(alignment: .leading) {
                // Tüm video
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { onScrub(time($0.location.x)) })

                // Seçilen aralık
                RoundedRectangle(cornerRadius: 6).fill(Brand.accent.opacity(0.22))
                    .frame(width: max(0, x(end) - x(start)))
                    .offset(x: x(start))
                    .allowsHitTesting(false)

                // Oynatma konumu
                Rectangle().fill(Color.primary.opacity(0.7))
                    .frame(width: 2)
                    .offset(x: x(current) - 1)
                    .allowsHitTesting(false)

                handle(at: x(start)) { start = min(time($0), end - 0.5); onScrub(start) }
                handle(at: x(end)) { end = max(time($0), start + 0.5); onScrub(end) }
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: 36)
    }

    private func handle(at px: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Brand.gradient)
            .frame(width: handleWidth)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 14))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .offset(x: px - handleWidth / 2)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { onDrag($0.location.x) })
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }
}

/// "1:23" biçiminde elle yazılabilen zaman alanı
private struct TimeField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.brand(10, BrandWeight.bold, width: BrandConfig.titleWidth - 5))
                .foregroundStyle(.secondary)
            TextField("0:00", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.brandMono(13, BrandWeight.medium))
                .frame(width: 92)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { isFocused in if !isFocused { commit() } }
                .onChange(of: value) { v in if !focused { text = formatClock(v) } }
                .onAppear { text = formatClock(value) }
                .help("Örnek: 1:23 ya da 1:02:03")
        }
    }

    private func commit() {
        if let v = parseClock(text) {
            value = min(max(v, range.lowerBound), range.upperBound)
            onCommit(value)
        }
        text = formatClock(value)
    }
}
