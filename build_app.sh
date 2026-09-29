#!/usr/bin/env bash
# Video indirici uygulamalarını derler. Her kurumun ayarları brands/<ad>/brand.conf içinde.
#
#   ./build_app.sh tip                 build/tip/<işlemci>/<Uygulama>.app (Apple Silicon + Intel)
#   ./build_app.sh egitimis --dmg      ayrıca build/<DMG_NAME>-AppleSilicon.dmg ve -Intel.dmg
#   ./build_app.sh all --dmg           tüm kurumlar
#   ./build_app.sh tip --arch arm64    sadece Apple Silicon (ya da --arch x86_64: sadece Intel)
#   ./build_app.sh tip --install       ayrıca bu Mac'e uygun olanı /Applications'a kopyalar
#   ./build_app.sh all --update-tools  vendor/ ve vendor-x64/ içindeki araçları yeniden indirir
#
# İmzalama (isteğe bağlı; yoksa ad-hoc imzalanır ve macOS ilk açılışta uyarı verir):
#   SIGN_IDENTITY="Developer ID Application: Ad Soyad (TEAMID)"   Developer ID ile imzalar
#   NOTARY_PROFILE="profil-adi"   DMG'yi Apple'a onaylatır (notarize) ve onayı DMG'ye ekler.
#                                 Profil bir kere şöyle kaydedilir:
#                                 xcrun notarytool store-credentials profil-adi \
#                                   --apple-id you@example.com --team-id TEAMID --password <uygulamaya-özel-şifre>
#
# DMG: markalı arka plan + (Apple onayı yoksa) resimli "Kurulum Rehberi.pdf". dmgbuild gerekir:
#   python3 -m pip install --user dmgbuild
#
# Gömülü araçlar (vendor/ = Apple Silicon, vendor-x64/ = Intel):
#   yt-dlp  – github.com/yt-dlp/yt-dlp (Python gerektirmeyen macOS sürümü; iki işlemciyi de destekler)
#   ffmpeg  – ffmpeg.martin-riedl.de (statik, sadece sistem kütüphanelerine bağlı)
#   deno    – github.com/denoland/deno (yt-dlp'nin YouTube için ihtiyaç duyduğu JS motoru)
set -euo pipefail
cd "$(dirname "$0")"

FFMPEG_URL_arm64="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip"
FFMPEG_URL_x86_64="https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2/ffmpeg.zip"
DENO_URL_arm64="https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
DENO_URL_x86_64="https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

SIGN_ID="${SIGN_IDENTITY:--}"     # "-" = ad-hoc
NOTARY="${NOTARY_PROFILE:-}"
if [[ -n "$NOTARY" && "$SIGN_ID" == "-" ]]; then
  echo "NOTARY_PROFILE için SIGN_IDENTITY (Developer ID) gerekli." >&2; exit 1
fi

TARGET="${1:-}"; [[ -n "$TARGET" ]] || usage
shift
DMG=false INSTALL=false UPDATE=false
ARCHS=(arm64 x86_64)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) DMG=true ;;
    --install) INSTALL=true ;;
    --update-tools) UPDATE=true ;;
    --arch) shift; [[ "${1:-}" == arm64 || "${1:-}" == x86_64 ]] || usage; ARCHS=("$1") ;;
    *) usage ;;
  esac
  shift
done

vendor_dir() { [[ "$1" == arm64 ]] && echo vendor || echo vendor-x64; }
arch_label() { [[ "$1" == arm64 ]] && echo AppleSilicon || echo Intel; }

if [[ "$TARGET" == "all" ]]; then
  BRANDS=(brands/*/)
  BRANDS=("${BRANDS[@]#brands/}"); BRANDS=("${BRANDS[@]%/}")
else
  [[ -f "brands/$TARGET/brand.conf" ]] || { echo "Bilinmeyen kurum: $TARGET (brands/ altına bakın)" >&2; exit 1; }
  BRANDS=("$TARGET")
fi

# --- Araçlar (tüm kurumlar için ortak) ---------------------------------------
fetch_tools() {
  # yt-dlp_macos iki işlemciyi de destekler; tek kopyası vendor/ içinde durur
  mkdir -p vendor
  $UPDATE && rm -f vendor/yt-dlp
  if [[ ! -x vendor/yt-dlp ]]; then
    echo "→ yt-dlp indiriliyor"
    curl -fSL --progress-bar -o vendor/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
  fi
  chmod +x vendor/yt-dlp

  for arch in "${ARCHS[@]}"; do
    local dir ffmpeg_url deno_url
    dir="$(vendor_dir "$arch")"
    ffmpeg_url="FFMPEG_URL_$arch"; ffmpeg_url="${!ffmpeg_url}"
    deno_url="DENO_URL_$arch"; deno_url="${!deno_url}"
    mkdir -p "$dir"
    $UPDATE && rm -f "$dir/ffmpeg" "$dir/deno"

    if [[ ! -x "$dir/ffmpeg" ]]; then
      echo "→ ffmpeg ($arch) indiriliyor"
      curl -fSL --progress-bar -o "$dir/ffmpeg.zip" "$ffmpeg_url"
      expected=$(curl -fsSL "$ffmpeg_url.sha256" | awk '{print $1}')
      actual=$(shasum -a 256 "$dir/ffmpeg.zip" | awk '{print $1}')
      [[ "$expected" == "$actual" ]] || { echo "ffmpeg sha256 uyuşmuyor!" >&2; exit 1; }
      unzip -oq "$dir/ffmpeg.zip" -d "$dir" && rm "$dir/ffmpeg.zip"
    fi
    if [[ ! -x "$dir/deno" ]]; then
      echo "→ deno ($arch) indiriliyor"
      curl -fSL --progress-bar -o "$dir/deno.zip" "$deno_url"
      unzip -oq "$dir/deno.zip" -d "$dir" && rm "$dir/deno.zip"
    fi
    chmod +x "$dir/ffmpeg" "$dir/deno"
    xattr -cr "$dir"
  done
}

# --- Bir kurumun uygulaması --------------------------------------------------
# Kuruma ait, işlemciden bağımsız parçalar: ayarlar, ikon, kurulum rehberi, DMG arka planı
prepare_brand() {
  local id="$1"
  # shellcheck disable=SC1090
  source "brands/$id/brand.conf"
  local out="build/$id"
  echo
  echo "━━ $APP_NAME"

  rm -rf "$out"
  mkdir -p "$out/assets"

  # Kurum ayarlarını Swift koduna dönüştür
  local mono="nil"; [[ -n "$MONO_PS" ]] && mono="\"$MONO_PS\""
  cat > "$out/BrandConfig.swift" <<EOF
// Bu dosya build_app.sh tarafından brands/$id/brand.conf'tan üretilir; elle düzenlemeyin.
import CoreGraphics

enum BrandConfig {
    static let appName = "$APP_NAME"
    static let tagline = "$TAGLINE"
    static let helpFooter = "$HELP_FOOTER"
    static let urlPlaceholder = "$URL_PLACEHOLDER"
    static let supportFolder = "$SUPPORT_DIR"
    static let accent: UInt32 = 0x$ACCENT
    static let accentDark: UInt32 = 0x$ACCENT_DARK
    static let fontName = "$FONT_PS"
    static let monoFontName: String? = $mono
    static let titleWidth: CGFloat = $TITLE_WIDTH
}
EOF

  echo "→ İkonlar"
  ICON_BG_TOP="$ICON_BG_TOP" ICON_BG_BOTTOM="$ICON_BG_BOTTOM" ICON_GLOSS="$ICON_GLOSS" \
  LOGO_SCALE="$LOGO_SCALE" BADGE_SIZE="$BADGE_SIZE" BADGE_Y="$BADGE_Y" \
  BADGE_FILL="$BADGE_FILL" BADGE_GLYPH="$BADGE_GLYPH" \
    swift app/tools/render_assets.swift "$LOGO" "$out/assets"
  iconutil -c icns "$out/assets/AppIcon.iconset" -o "$out/assets/AppIcon.icns"

  if $DMG; then
    python3 -c "import dmgbuild" 2>/dev/null || { echo "dmgbuild gerekli: python3 -m pip install --user dmgbuild" >&2; exit 1; }
    echo "→ Kurulum rehberi ve DMG arka planı"
    # Şablon değişkenleri (app/installer/*.html)
    export TPL_APP_NAME="$APP_NAME" TPL_ACCENT="$ACCENT" TPL_ACCENT_DARK="$ACCENT_DARK" \
           TPL_ICON_FILE="$out/assets/AppIcon.iconset/icon_128x128@2x.png" TPL_FONT_FILE="brands/$id/Fonts/$FONT_FILE"
    if [[ -z "$NOTARY" ]]; then
      export TPL_HELP_DISPLAY="block"
      swift app/tools/render_html.swift pdf app/installer/guide.html "$out/Kurulum Rehberi.pdf"
    else
      export TPL_HELP_DISPLAY="none"
    fi
    # Tasarım 760×620; tuval, Finder pencereyi büyük açarsa boşluk kalmasın diye daha geniş
    export TPL_CANVAS_W=1300 TPL_CANVAS_H=1000
    TPL_ZOOM=1 swift app/tools/render_html.swift png app/installer/background.html "$out/assets/background.png" 1300 1000
    TPL_ZOOM=2 swift app/tools/render_html.swift png app/installer/background.html "$out/assets/background@2x.png" 2600 2000
    tiffutil -cathidpicheck "$out/assets/background.png" "$out/assets/background@2x.png" -out "$out/assets/background.tiff" 2>/dev/null
  fi
}

# Bir kurumun bir işlemci türü için uygulaması (ve DMG'si)
build_arch() {
  local id="$1" arch="$2"
  local out="build/$id" label; label="$(arch_label "$arch")"
  local APP="$out/$arch/$APP_NAME.app" tools; tools="$(vendor_dir "$arch")"
  echo "→ $label ($arch) derleniyor"

  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    app/Sources/*.swift "$out/BrandConfig.swift" -o "$APP/Contents/MacOS/$EXE"

  cp "$out/assets/AppIcon.icns" "$APP/Contents/Resources/"
  cp "$out/assets/AppIcon.iconset/icon_128x128@2x.png" "$APP/Contents/Resources/header-icon.png"
  cp -R "brands/$id/Fonts" "$APP/Contents/Resources/Fonts"

  cp vendor/yt-dlp "$tools/ffmpeg" "$tools/deno" "$APP/Contents/Resources/bin/"
  # yt-dlp ilk açılışta kendini geçici klasöre açar; nadiren G/Ç hatası verirse tekrar dene
  for _ in 1 2 3; do
    vendor/yt-dlp --version > "$APP/Contents/Resources/bin/yt-dlp.version" 2>/dev/null && break
    sleep 1
  done
  [[ -s "$APP/Contents/Resources/bin/yt-dlp.version" ]] || { echo "yt-dlp sürümü okunamadı" >&2; exit 1; }

  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

  # ffmpeg ve deno üreticilerinin Developer ID imzasıyla geliyor; onlara dokunulmaz.
  if [[ "$SIGN_ID" == "-" ]]; then
    echo "→ İmzalanıyor (ad-hoc)"
    codesign --force --sign - "$APP/Contents/Resources/bin/yt-dlp"
    codesign --force --sign - "$APP"
  else
    echo "→ İmzalanıyor ($SIGN_ID)"
    codesign --force --timestamp --options runtime \
      --entitlements app/signing/yt-dlp.entitlements --sign "$SIGN_ID" "$APP/Contents/Resources/bin/yt-dlp"
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP"
    codesign --verify --deep --strict "$APP"
  fi
  echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

  if $DMG; then
    local dmg="build/$DMG_NAME-$label.dmg"
    rm -f "$dmg"
    local guide_args=()
    [[ -z "$NOTARY" ]] && guide_args=(-D "guide=$out/Kurulum Rehberi.pdf")

    python3 -m dmgbuild -s app/installer/dmg_settings.py \
      -D "app=$APP" -D "background=$out/assets/background.tiff" "${guide_args[@]}" \
      "$APP_NAME" "$dmg" >/dev/null

    # DMG içindeki uygulamanın imzası sağlam mı? (Bozuksa başka Mac'lerde "açılamıyor" hatası verir)
    local mnt; mnt="$(mktemp -d)"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
    if ! codesign --verify --deep --strict "$mnt/$APP_NAME.app" 2>"$out/$arch/dmg-verify.log"; then
      hdiutil detach -quiet "$mnt"; cat "$out/$arch/dmg-verify.log" >&2
      echo "DMG içindeki uygulamanın imzası geçersiz!" >&2; exit 1
    fi
    hdiutil detach -quiet "$mnt"
    echo "✓ DMG içindeki imza doğrulandı"

    if [[ "$SIGN_ID" != "-" ]]; then
      codesign --force --timestamp --sign "$SIGN_ID" "$dmg"
    fi
    if [[ -n "$NOTARY" ]]; then
      echo "→ Apple onayına gönderiliyor (birkaç dakika sürebilir)"
      xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY" --wait
      xcrun stapler staple "$dmg"
      spctl --assess --type open --context context:primary-signature -v "$dmg"
    fi
    echo "✓ $dmg ($(du -h "$dmg" | cut -f1))"
  fi

  if $INSTALL && [[ "$arch" == "$(uname -m)" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "✓ /Applications/$APP_NAME.app"
  fi
}

fetch_tools
rm -f build/*.dmg   # eski adlandırmayla (işlemci türü olmadan) kalmış DMG'ler
for id in "${BRANDS[@]}"; do
  prepare_brand "$id"
  for arch in "${ARCHS[@]}"; do
    build_arch "$id" "$arch"
  done
done
