import AVKit
import SwiftUI

/// Kesim önizlemesi için oynatıcı: aralığı oynatırken bitişte durur.
@MainActor
final class ClipPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var current: Double = 0
    @Published var isPlaying = false
    @Published var failed = false

    private var stopAt: Double?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var loadedURL: URL?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds.isFinite ? time.seconds : 0
                if let stop = self.stopAt, self.current >= stop { self.pause(); self.seek(stop) }
            }
        }
    }

    func load(_ url: URL, headers: [String: String]) {
        guard url != loadedURL else { return }
        loadedURL = url
        failed = false
        // Bazı siteler (ör. YouTube) akışa yalnızca yt-dlp'nin kullandığı başlıklarla izin verir
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { self?.failed = item.status == .failed }
        }
        player.replaceCurrentItem(with: item)
    }

    func seek(_ t: Double) {
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(until end: Double? = nil) {
        stopAt = end
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopAt = nil
    }

    func playRange(_ start: Double, _ end: Double) {
        seek(start)
        play(until: end)
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
                if let preview, let url = preview.url.flatMap(URL.init(string:)), !clip.failed {
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
                    .onAppear { clip.load(url, headers: preview.http_headers ?? [:]); clip.seek(state.clipStart) }
                    .onDisappear { clip.pause() }
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
                    .disabled(preview == nil || clip.failed)

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
