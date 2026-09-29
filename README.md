<p align="center">
  <img src="docs/icon.png" width="128" alt="TİP Video İndirici">
</p>

<h1 align="center">TİP Video İndirici</h1>

<p align="center">
  YouTube, X (Twitter), Instagram ve 1000'den fazla siteden video ve ses indirmek için Mac ve Windows uygulaması.<br>
  <b>TİP Propaganda Bürosu</b> tarafından üretilmiştir.
</p>

<p align="center">
  <a href="https://kerimcankara-git.github.io/tip-video-indirici/"><b>🌐 Tanıtım ve indirme sayfası</b></a>
</p>

---

## İndir

| Bilgisayar | Dosya |
|---|---|
| **Mac – Apple Silicon** (M1, M2, M3, M4…) | [TIP-Video-Indirici-AppleSilicon.dmg](../../releases/latest/download/TIP-Video-Indirici-AppleSilicon.dmg) |
| **Mac – Intel** | [TIP-Video-Indirici-Intel.dmg](../../releases/latest/download/TIP-Video-Indirici-Intel.dmg) |
| **Windows 10 / 11** (64 bit) | [TIP-Video-Indirici-Setup.exe](../../releases/latest/download/TIP-Video-Indirici-Setup.exe) |

Tüm sürümler: [Releases](../../releases)

**Mac'imde hangi çip var?** Apple menüsü › **Bu Mac Hakkında**. “Çip: Apple M…” yazıyorsa *Apple Silicon*, “İşlemci: Intel” yazıyorsa *Intel* dosyasını indirin. En az macOS 13 (Ventura) gerekir.

## Kurulum

### Mac
1. DMG dosyasını açın, uygulama simgesini **Applications** klasörüne sürükleyin.
2. Uygulamayı açın. İlk açılışta *“Apple doğrulayamadı”* uyarısı çıkması normaldir; **Bitti**'ye basın (**Çöp Sepetine Taşı**'ya değil).
3. **Sistem Ayarları › Gizlilik ve Güvenlik**'i açın, en alta kaydırın ve **Yine de Aç**'a basın; Mac şifrenizi girin.

Bu izin yalnızca bir kez verilir. DMG içindeki *Kurulum Rehberi* adımları resimli olarak anlatır.

### Windows
1. `TIP-Video-Indirici-Setup.exe` dosyasını çalıştırın.
2. *“Windows bilgisayarınızı korudu”* uyarısı çıkarsa **Ek bilgi › Yine de çalıştır**'a basın.
3. Kurulum yönetici izni istemeden tamamlanır; masaüstüne ve Başlat menüsüne kısayol eklenir.

> Uyarılar, uygulama henüz ücretli bir Apple / Microsoft geliştirici sertifikasıyla imzalanmadığı için çıkar.

## Özellikler

- **Otomatik algılama:** YouTube, X ve Instagram bağlantısını kopyalayıp uygulamaya dönmeniz yeterli.
- **Video, sadece ses veya gelişmiş format seçimi;** 4K'ya kadar kalite, MP3 / M4A / WAV / FLAC / OPUS.
- **Düzenleme programlarıyla uyumlu MP4:** 1080p üstü videolar QuickTime, Premiere ve Final Cut'ın açabileceği biçime otomatik dönüştürülür.
- **Aynı anda birden fazla indirme**, iptal etme, klasörde gösterme.
- **Oturum desteği:** Giriş gerektiren Instagram / X gönderileri için tarayıcınızdaki oturum kullanılır; uygulamaya şifre girilmez.
- **Tek tıkla güncelleme:** Siteler değiştiğinde indirme aracı (yt-dlp) uygulama içinden güncellenir.
- Uygulama içinde **Nasıl Kullanılır** rehberi (Mac: ⌘?, Windows: F1).

Sorunlarınızı örgüt kanalıyla iletebilirsiniz.

---

## Kaynaktan derleme

| Klasör | İçerik |
|---|---|
| `app/Sources` | Mac uygulaması (SwiftUI) |
| `app/installer`, `app/tools` | DMG arka planı, kurulum rehberi, ikon üretimi |
| `windows/` | Windows uygulaması (Electron) |
| `brands/tip` | Ad, renkler, font ve ikon ayarları |

**Mac** (Xcode komut satırı araçları ve `python3 -m pip install --user dmgbuild` gerekir):

```bash
./build_app.sh tip --dmg          # build/TIP-Video-Indirici-AppleSilicon.dmg ve -Intel.dmg
```

**Windows** (bir Mac'te derlenir; Node.js gerekir):

```bash
cd windows && npm install && cd ..
./build_windows.sh tip            # build/windows/TIP-Video-Indirici-Setup.exe
```

Gömülü araçlar (yt-dlp, ffmpeg, deno) derleme sırasında resmi kaynaklarından indirilir.

## Lisanslar

Kaynak kod [MIT lisansı](LICENSE) ile yayımlanmıştır. TİP adı ve logosu bu lisansın kapsamında değildir.
Uygulamayla birlikte dağıtılan üçüncü taraf yazılımlar ve fontlar için bkz. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Yalnızca indirme ve kullanma hakkınız olan içerikleri indirin.
