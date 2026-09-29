import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Header()
                    URLBar()
                    if let info = state.info {
                        VideoCard(info: info)
                        OptionsCard(info: info)
                        if state.clipAvailable { ClipCard(info: info) }
                        DownloadButton()
                    } else if !state.isFetching {
                        EmptyHint()
                    }
                    DownloadList()
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.info?.id)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.jobs.map(\.id))
            }
            Footer()
        }
        .background(Background())
        .background(WindowCloseGuard())
        .sheet(isPresented: $state.showHelp) { HelpView().tint(Brand.accent) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            state.urlText = url.absoluteString
            state.fetch()
            return true
        }
    }
}

// MARK: - Arka plan & başlık

private struct Background: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Brand.accent.opacity(scheme == .dark ? 0.22 : 0.12), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

private struct Header: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let icon = Brand.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .padding(-6)   // ikon görselindeki kenar boşluğunu dengeler
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(BrandConfig.appName).font(.brand(23, BrandWeight.extraBold, width: BrandConfig.titleWidth))
                Text(BrandConfig.tagline)
                    .font(.brand(12.5, BrandWeight.medium)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button { state.showHelp = true } label: {
                Label("Nasıl Kullanılır", systemImage: "questionmark.circle")
            }
            .buttonStyle(PillButtonStyle(filled: false))
            .help("Kullanım rehberi (⌘?)")
        }
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Brand.accent.opacity(0.8))
            Text("YouTube, X (Twitter) ya da Instagram bağlantısı yapıştır veya buraya sürükle")
                .font(.brand(13.5, BrandWeight.medium)).foregroundStyle(.secondary)
            Text("Panoda bir bağlantı varsa uygulamaya döndüğünde otomatik algılanır.")
                .font(.brand(11.5)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Card.shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(Color.primary.opacity(0.12)))
    }
}

// MARK: - Bağlantı alanı

private struct URLBar: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField(BrandConfig.urlPlaceholder, text: $state.urlText)
                    .textFieldStyle(.plain)
                    .font(.brand(15))
                    .focused($focused)
                    .onSubmit { state.fetch() }
                if !state.urlText.isEmpty {
                    Button { state.clear() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Temizle")
                }
                if state.urlText.isEmpty {
                    Button { state.paste() } label: {
                        Label("Yapıştır", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(PillButtonStyle(filled: false))
                } else {
                    Button { state.fetch() } label: {
                        if state.isFetching {
                            ProgressView().controlSize(.small).tint(.white).frame(width: 44)
                        } else {
                            Text("Getir").frame(width: 44)
                        }
                    }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(state.isFetching || !state.toolsReady)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Card.shape.fill(.background.opacity(0.9)))
            .overlay(Card.shape.strokeBorder(focused ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.1),
                                             lineWidth: focused ? 2 : 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)

            if let error = state.fetchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.brand(13, BrandWeight.medium))
                    .foregroundStyle(Brand.danger)
                    .textSelection(.enabled)
                if state.fetchNeedsLogin {
                    Hint(icon: "person.badge.key", text: state.cookiesBrowser.isEmpty
                         ? "Bu içerik giriş gerektiriyor olabilir (Instagram'da sık olur). Alt çubuktaki \"Oturum\" menüsünden hesabına giriş yaptığın tarayıcıyı seçip tekrar dene."
                         : "Seçili tarayıcıda bu siteye giriş yapmış olduğundan emin ol, ya da başka bir tarayıcı seç.")
                }
            }
        }
    }
}

// MARK: - Video kartı

private struct VideoCard: View {
    let info: VideoInfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: info.displayThumbnail.flatMap(URL.init(string:))) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.primary.opacity(0.08))
                }
                .frame(width: 208, height: 117)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let d = info.displayDuration {
                    Text(formatDuration(d))
                        .font(.brandMono(11, BrandWeight.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let platform = info.platform { Tag(text: platform) }
                    if info.videoCount > 1 { Tag(text: "\(info.videoCount) video · hepsi indirilir") }
                }
                Text(info.displayTitle)
                    .font(.brand(17, BrandWeight.bold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let uploader = info.uploader {
                    Label(uploader, systemImage: "person.crop.circle")
                        .font(.brand(13, BrandWeight.medium)).foregroundStyle(.secondary)
                }
                if let best = info.heights.first {
                    Text("En yüksek kalite: \(qualityLabel(best))")
                        .font(.brand(11.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Seçenekler

private struct OptionsCard: View {
    @EnvironmentObject var state: AppState
    let info: VideoInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModePicker(mode: $state.mode)

            switch state.mode {
            case .video: videoOptions
            case .audio: audioOptions
            case .custom: FormatTable(formats: info.usableFormats, selection: $state.customFormat)
            }
        }
        .card()
    }

    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            OptionRow(title: "Kalite") {
                Chip(title: "En iyi", selected: state.height == nil) { state.height = nil }
                ForEach(info.heights, id: \.self) { h in
                    Chip(title: qualityLabel(h), subtitle: h > 1080 ? "\(h)p" : nil,
                         selected: state.height == h) { state.height = h }
                }
            }
            OptionRow(title: "Format") {
                Chip(title: "MP4", subtitle: "Mac uyumlu", selected: state.container == "mp4") { state.container = "mp4" }
                Chip(title: "MKV", selected: state.container == "mkv") { state.container = "mkv" }
                Chip(title: "WEBM", selected: state.container == "webm") { state.container = "webm" }
            }
            if state.willConvert {
                Hint(icon: "cpu", text: "1080p üstü kaliteler H.264 olarak sunulmuyor. İndirme sonrası donanım hızlandırmalı HEVC'ye çevrilecek; QuickTime ve Premiere doğrudan açar.")
            } else if state.container != "mp4" {
                Hint(icon: "info.circle", text: "MKV/WEBM dosyaları AV1 veya VP9 içerebilir; QuickTime ve Premiere açamayabilir.")
            }
        }
    }

    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            OptionRow(title: "Format") {
                ForEach(["mp3", "m4a", "wav", "flac", "opus"], id: \.self) { f in
                    Chip(title: f.uppercased(), subtitle: lossless(f) ? "kayıpsız" : nil,
                         selected: state.audioFormat == f) { state.audioFormat = f }
                }
            }
            if !lossless(state.audioFormat) {
                OptionRow(title: "Bit hızı") {
                    ForEach([128, 192, 256, 320], id: \.self) { q in
                        Chip(title: "\(q)", subtitle: "kbps", selected: state.audioQuality == q) { state.audioQuality = q }
                    }
                }
            }
        }
    }
}

private struct ModePicker: View {
    @Binding var mode: Mode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { m in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = m }
                } label: {
                    Label(m.title, systemImage: m.icon)
                        .font(.brand(13, BrandWeight.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(mode == m ? Color.white : Color.primary)
                        .background {
                            if mode == m {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Brand.gradient)
                                    .matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

private struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.brand(10, BrandWeight.bold, width: BrandConfig.titleWidth - 5))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) { content }
        }
    }
}

private struct Chip: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.brand(13, BrandWeight.bold))
                if let subtitle {
                    Text(subtitle).font(.brand(9.5, BrandWeight.medium)).opacity(0.75)
                }
            }
            .frame(minWidth: 58, minHeight: 32)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.1 : 0.05))))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.brand(10.5, BrandWeight.bold))
            .foregroundStyle(Brand.accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Brand.accent.opacity(0.12)))
    }
}

struct Hint: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.brand(11.5))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.accent.opacity(0.07)))
    }
}

private struct FormatTable: View {
    let formats: [VideoFormat]
    @Binding var selection: VideoFormat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bir format seç. Sadece video içeren formatlara en iyi ses otomatik eklenir.")
                .font(.brand(11.5)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(formats.reversed()) { f in
                        let selected = selection == f
                        Button { selection = f } label: {
                            HStack {
                                Text(f.format_id).font(.brandMono(11.5, BrandWeight.medium)).frame(width: 64, alignment: .leading)
                                Text(f.kind).frame(width: 74, alignment: .leading)
                                Text(f.ext ?? "").frame(width: 48, alignment: .leading)
                                Text(f.resolution).frame(width: 96, alignment: .leading)
                                Text(f.codecs).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                Text(formatBytes(f.size)).frame(width: 72, alignment: .trailing)
                            }
                            .font(.brand(12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.clear)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: - İndir düğmesi

private struct DownloadButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.startDownload() } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18))
                Text("İndir").font(.brand(15.5, BrandWeight.extraBold, width: BrandConfig.titleWidth - 5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(PillButtonStyle(filled: true, large: true))
        .disabled(!state.canDownload)
        .keyboardShortcut(.return, modifiers: .command)
    }
}

// MARK: - İndirme listesi

private struct DownloadList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if !state.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("İndirmeler").font(.brand(15, BrandWeight.bold, width: BrandConfig.titleWidth - 5))
                    Spacer()
                    if state.jobs.contains(where: { !$0.isActive }) {
                        Button("Bitenleri temizle") { state.clearFinished() }
                            .buttonStyle(.plain)
                            .font(.brand(11.5, BrandWeight.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(state.jobs) { job in
                    JobRow(job: job)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct JobRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var job: DownloadJob

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: job.thumbnail) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.primary.opacity(0.08))
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .center) { statusBadge }

            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.brand(13.5, BrandWeight.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.summary)
                        .font(.brand(10, BrandWeight.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Text(job.detail)
                        .font(.brandMono(11))
                        .foregroundStyle(job.phase == .failed ? Brand.danger : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if job.isActive {
                    ProgressBar(value: job.phase == .processing || job.indeterminate ? nil : job.progress)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if job.isActive {
                    IconButton(icon: "xmark", help: "İptal") { job.cancel() }
                } else {
                    if job.phase == .done {
                        IconButton(icon: "play.fill", help: "Aç") { job.open() }
                        IconButton(icon: "magnifyingglass", help: "Finder'da göster") { job.reveal() }
                    }
                    IconButton(icon: "trash", help: "Listeden kaldır") { state.remove(job) }
                }
            }
        }
        .padding(12)
        .background(Card.shape.fill(.background.opacity(0.7)))
        .overlay(Card.shape.strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var statusBadge: some View {
        switch job.phase {
        case .done: badge("checkmark", .green)
        case .failed: badge("exclamationmark", Brand.danger)
        case .cancelled: badge("xmark", .gray)
        default: EmptyView()
        }
    }

    private func badge(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(color))
            .shadow(radius: 3)
    }
}

private struct ProgressBar: View {
    let value: Double?   // nil = belirsiz
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let value {
                    Capsule().fill(Brand.gradient)
                        .frame(width: max(6, geo.size.width * value))
                        .animation(.easeOut(duration: 0.3), value: value)
                } else {
                    Capsule().fill(Brand.gradient)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { phase = 1 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }
}

// MARK: - Alt bilgi

private struct Footer: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Button { state.openFolder() } label: {
                Label(state.downloadDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                      systemImage: "folder.fill")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Klasörü aç")
            Button("Değiştir…") { state.chooseFolder() }
                .buttonStyle(.link)

            Spacer()

            Menu {
                Picker("Oturum", selection: $state.cookiesBrowser) {
                    ForEach(cookieBrowsers, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.inline)
                Divider()
                Text("Instagram ve bazı X gönderileri giriş ister. Seçilen tarayıcıdaki oturum kullanılır.")
                Text("Safari için: Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi'nden bu uygulamaya izin ver.")
            } label: {
                Label("Oturum: " + (cookieBrowsers.first { $0.0 == state.cookiesBrowser }?.1 ?? "—")
                        .replacingOccurrences(of: "Oturum kullanma", with: "Yok"),
                      systemImage: state.cookiesBrowser.isEmpty ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Giriş gerektiren içerikler için tarayıcı oturumu")

            if let msg = state.toolMessage {
                Text(msg).foregroundStyle(.secondary).lineLimit(1)
            }
            if state.isUpdating {
                ProgressView().controlSize(.small)
            } else {
                Button { state.updateTools() } label: {
                    Label(state.ytdlpVersion.isEmpty ? "yt-dlp" : "yt-dlp \(state.ytdlpVersion)",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .help("Sitelerde bir değişiklik olunca indirmeler bozulabilir; buradan yt-dlp'yi güncelle.")
                .disabled(!state.toolsReady)
            }
        }
        .font(.brand(11.5, BrandWeight.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}

// MARK: - Ortak parçalar

enum Card {
    static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
}

extension View {
    func card() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Card.shape.fill(.background.opacity(0.85)))
            .overlay(Card.shape.strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

struct PillButtonStyle: ButtonStyle {
    var filled: Bool
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(13, BrandWeight.semibold))
            .padding(.horizontal, large ? 0 : 14)
            .padding(.vertical, large ? 0 : 7)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous)
                .fill(filled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .shadow(color: filled && enabled ? Brand.accent.opacity(0.35) : .clear, radius: large ? 10 : 4, y: large ? 5 : 2)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Çipleri satıra sığmadığında alt satıra kaydırır.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
