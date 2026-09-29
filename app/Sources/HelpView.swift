import SwiftUI

/// "Nasıl Kullanılır" penceresi. İçerik Windows sürümündeki (windows/src/renderer/index.html #help) ile aynı tutulmalı.
enum HelpContent {
    /// Panodan otomatik algılanan platformlar
    static let autoPlatforms = ["YouTube", "X (Twitter)", "Instagram"]
    /// Bağlantıyı elle yapıştırarak indirilebilen popüler platformlar (yt-dlp destekli)
    static let otherPlatforms = [
        "TikTok", "Facebook", "Vimeo", "Reddit", "Twitch", "Dailymotion", "SoundCloud", "Bandcamp",
        "Bluesky", "LinkedIn", "Pinterest", "Tumblr", "Streamable", "Kick", "Rumble", "Bilibili",
    ]
    static let supportedSitesURL = URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Nasıl Kullanılır", systemImage: "questionmark.circle.fill")
                    .font(.brand(18, BrandWeight.extraBold, width: BrandConfig.titleWidth))
                    .foregroundStyle(Brand.accent)
                Spacer()
                Button("Kapat") { dismiss() }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
            .overlay(Divider(), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    quickStart
                    platforms
                    modes
                    clip
                    session
                    folder
                    update
                    troubleshooting
                    Text(BrandConfig.helpFooter)   // brands/<ad>/brand.conf › HELP_FOOTER
                        .font(.brand(11, BrandWeight.medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(24)
            }
        }
        .frame(width: 620, height: 680)
        .font(.brand(13))
    }

    // MARK: Bölümler

    private var quickStart: some View {
        HelpSection(icon: "bolt.fill", title: "Hızlı başlangıç") {
            Step(1, "Videonun bağlantısını kopyala (tarayıcıda adres çubuğundan ya da uygulamada **Paylaş › Bağlantıyı Kopyala**).")
            Step(2, "Uygulamaya dön: desteklenen bir bağlantıysa **kendiliğinden algılanır**. Algılanmazsa **Yapıştır**'a bas ya da bağlantıyı pencereye sürükle.")
            Step(3, "Video / Sadece Ses seçip kaliteyi ve formatı belirle.")
            Step(4, "**İndir**'e bas (⌘ Enter). Birden fazla videoyu aynı anda indirebilirsin; ilerlemeyi aşağıdaki listede görürsün.")
        }
    }

    private var platforms: some View {
        HelpSection(icon: "globe", title: "Desteklenen platformlar") {
            Text("Panodan **otomatik algılananlar:**")
            FlowLayout(spacing: 6) {
                ForEach(HelpContent.autoPlatforms, id: \.self) { PlatformTag(name: $0, highlighted: true) }
            }
            Text("Bağlantıyı **yapıştırarak** indirebileceğin diğer popüler siteler:")
                .padding(.top, 4)
            FlowLayout(spacing: 6) {
                ForEach(HelpContent.otherPlatforms, id: \.self) { PlatformTag(name: $0, highlighted: false) }
            }
            HStack(spacing: 4) {
                Text("…ve 1000'den fazlası.")
                Link("Tam listeyi gör ↗", destination: HelpContent.supportedSitesURL)
                    .foregroundStyle(Brand.accent)
            }
            .padding(.top, 2)
        }
    }

    private var modes: some View {
        HelpSection(icon: "slider.horizontal.3", title: "İndirme seçenekleri") {
            Bullet("**Video:** Kaliteyi seç (En iyi, 4K, 1080p…). **MP4** QuickTime, Premiere ve Final Cut ile uyumludur; 1080p üstü videolar indirme sonrası otomatik olarak HEVC'ye çevrilir. MKV/WEBM dönüştürülmez.")
            Bullet("**Sadece Ses:** MP3, M4A, WAV, FLAC veya OPUS; kayıplı formatlarda bit hızını seçebilirsin.")
            Bullet("**Gelişmiş:** Sitenin sunduğu tüm formatları listeler; belirli bir formatı seçmek için.")
            Bullet("Bir gönderide birden fazla video varsa (ör. tweet, Instagram carousel) hepsi indirilir.")
        }
    }

    private var clip: some View {
        HelpSection(icon: "scissors", title: "Videonun bir kısmını indirme") {
            Text("Uzun bir videonun sadece bir bölümüne ihtiyacın varsa tamamını indirmen gerekmez.")
            Step(1, "Seçeneklerin altındaki **Sadece bir kısmını indir** anahtarını aç; video önizlemesi görünür.")
            Step(2, "Zaman çizelgesindeki iki tutamacı sürükleyerek başlangıcı ve bitişi seç. İstersen **1:23** gibi elle yaz ya da oynatıcıyı istediğin yere getirip **Şu an**'a bas.")
            Step(3, "**Seçimi oynat** ile kontrol et, sonra **İndir**. Aralık dosya adına eklenir, ör. *(1.23-2.45)*.")
            Bullet("Kesimler tam seçtiğin saniyeden yapılır; bu yüzden kesilen parçanın indirilmesi biraz daha uzun sürebilir.")
            Bullet("Birden fazla video içeren gönderilerde ve canlı yayınlarda bu seçenek görünmez.")
        }
    }

    private var session: some View {
        HelpSection(icon: "person.crop.circle.badge.checkmark", title: "Oturum açma (Instagram vb.)") {
            Text("Instagram'daki çoğu gönderi ve bazı X videoları giriş ister. Uygulamaya şifre girmezsin; bunun yerine o siteye **giriş yaptığın tarayıcının oturumu** kullanılır.")
            Step(1, "Tarayıcında (Chrome, Safari, Firefox…) Instagram'a giriş yap.")
            Step(2, "Uygulamanın alt çubuğundaki **Oturum** menüsünden o tarayıcıyı seç.")
            Step(3, "Bağlantıyı tekrar getir.")
            Bullet("**Safari** için: Sistem Ayarları › Gizlilik ve Güvenlik › **Tam Disk Erişimi**'nden bu uygulamaya izin ver.")
            Bullet("**Chrome / Brave / Edge** ilk seferde anahtar zinciri izni isteyebilir; **Her Zaman İzin Ver** de.")
        }
    }

    private var folder: some View {
        HelpSection(icon: "folder.fill", title: "İndirme klasörü") {
            Text("Dosyalar varsayılan olarak **İndirilenler › \(BrandConfig.appName)** klasörüne kaydedilir.")
            Bullet("Alt çubuktaki klasör yoluna tıklayınca klasör açılır.")
            Bullet("**Değiştir…** ile başka bir klasör seçebilirsin; seçimin hatırlanır.")
            Bullet("Biten bir indirmenin yanındaki ▶ dosyayı açar, 🔍 Finder'da gösterir.")
        }
    }

    private var update: some View {
        HelpSection(icon: "arrow.triangle.2.circlepath", title: "yt-dlp'yi güncelleme") {
            Text("İndirmeleri **yt-dlp** adlı açık kaynak araç yapar. YouTube ve diğer siteler sık değiştiği için bir gün indirmeler hata vermeye başlarsa ilk yapılacak şey güncellemektir:")
            Bullet("Alt çubuğun sağındaki **yt-dlp** sürüm numarasına tıkla. Birkaç saniye içinde en son sürüm indirilir; uygulamayı yeniden yüklemen gerekmez.")
        }
    }

    private var troubleshooting: some View {
        HelpSection(icon: "wrench.and.screwdriver.fill", title: "Sorun giderme") {
            Bullet("**“Video bilgileri alınamadı”** ya da benzeri bir hata: önce yt-dlp'yi güncelle, sonra tekrar dene.")
            Bullet("**Giriş gerektiriyor** uyarısı: yukarıdaki *Oturum açma* adımlarını uygula.")
            Bullet("**Özel ya da yaş sınırlı** videolar yalnızca oturum açıkken indirilebilir.")
            Bullet("İndirme yarıda kaldıysa listeden kaldırıp yeniden başlatabilirsin.")
        }
    }
}

// MARK: - Parçalar

private struct HelpSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.brand(15, BrandWeight.bold, width: BrandConfig.titleWidth - 5))
                .foregroundStyle(.primary)
                .labelStyle(AccentIconLabelStyle())
            VStack(alignment: .leading, spacing: 6) { content }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Card.shape.fill(Color.primary.opacity(0.035)))
    }
}

private struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Brand.accent).frame(width: 20)
            configuration.title
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey
    init(_ number: Int, _ text: LocalizedStringKey) { self.number = number; self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.brand(11, BrandWeight.extraBold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Brand.gradient))
            Text(text)
        }
    }
}

private struct Bullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Brand.accent).frame(width: 5, height: 5).offset(y: -2)
            Text(text)
        }
    }
}

private struct PlatformTag: View {
    let name: String
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            if highlighted { Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)) }
            Text(name)
        }
        .font(.brand(11.5, BrandWeight.semibold))
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(highlighted ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
    }
}
