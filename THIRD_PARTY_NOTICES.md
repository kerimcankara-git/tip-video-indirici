# Üçüncü taraf yazılımlar

TİP Video İndirici, aşağıdaki açık kaynak yazılımları ve fontları değiştirmeden, ayrı programlar olarak içerir.
Her biri kendi lisansına tabidir.

| Bileşen | Sürüm | Lisans | Kaynak |
|---|---|---|---|
| **yt-dlp** – video indirme aracı | 2026.08.19 | [The Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) | https://github.com/yt-dlp/yt-dlp |
| **FFmpeg** – video/ses dönüştürme | 9.0.2 | [GNU GPL v3 veya sonrası](https://www.gnu.org/licenses/gpl-3.0.html) | https://ffmpeg.org/download.html |
| **Deno** – JavaScript çalışma ortamı (yt-dlp için) | 2.9.7 | [MIT](https://github.com/denoland/deno/blob/main/LICENSE.md) | https://github.com/denoland/deno |
| **Electron** – Windows uygulama çatısı | 38.8.6 | [MIT](https://github.com/electron/electron/blob/main/LICENSE) | https://github.com/electron/electron |
| **Mona Sans** – yazı tipi | – | [SIL Open Font License 1.1](brands/tip/Fonts/OFL.txt) | https://github.com/github/mona-sans |

## FFmpeg

FFmpeg ikili dosyaları, GPL etkin (`--enable-gpl --enable-version3`) olarak derlenmiş hazır sürümlerdir:

- **macOS (Apple Silicon ve Intel):** Martin Riedl derlemeleri – https://ffmpeg.martin-riedl.de
- **Windows (x64):** Gyan Doshi “release essentials” derlemesi – https://www.gyan.dev/ffmpeg/builds/

Bu derlemelerin karşılık gelen kaynak kodu FFmpeg projesinden (https://ffmpeg.org/releases/) ve yukarıdaki
derleyicilerin sayfalarından edinilebilir. Talep halinde kullanılan kaynak kodun bir kopyası da sağlanır.

## Electron / Chromium

Windows sürümü Electron ile birlikte gelir; Chromium ve diğer bileşenlerin lisans metinleri kurulum klasöründeki
`LICENSES.chromium.html` dosyasındadır.
