#!/usr/bin/env bash
# Windows sürümünü (Electron) derler. Kurum ayarları Mac sürümüyle aynı: brands/<ad>/brand.conf
#
#   ./build_windows.sh tip               build/windows/<DMG_NAME>-Setup.exe
#   ./build_windows.sh all               tüm kurumlar
#   ./build_windows.sh tip --stage       sadece windows/src'yi o kurum için hazırlar (geliştirme:
#                                        cd windows && env -u ELECTRON_RUN_AS_NODE npx electron .)
#   ./build_windows.sh all --update-tools   vendor-win/ içindeki araçları yeniden indirir
#
# Gereksinimler: Node.js (windows/ içinde bir kere `npm install`), Swift (ikon üretimi için).
# Gömülü araçlar (Windows x64): yt-dlp.exe (GitHub), ffmpeg.exe (gyan.dev essentials), deno.exe (GitHub),
#                               cacert.pem (curl.se; ffmpeg'in HTTPS sertifika doğrulaması için)
set -euo pipefail
cd "$(dirname "$0")"
unset ELECTRON_RUN_AS_NODE

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

TARGET="${1:-}"; [[ -n "$TARGET" ]] || usage
shift
STAGE_ONLY=false UPDATE=false
for arg in "$@"; do
  case "$arg" in
    --stage) STAGE_ONLY=true ;;
    --update-tools) UPDATE=true ;;
    *) usage ;;
  esac
done

if [[ "$TARGET" == "all" ]]; then
  BRANDS=(brands/*/); BRANDS=("${BRANDS[@]#brands/}"); BRANDS=("${BRANDS[@]%/}")
else
  [[ -f "brands/$TARGET/brand.conf" ]] || { echo "Bilinmeyen kurum: $TARGET" >&2; exit 1; }
  BRANDS=("$TARGET")
fi

# --- Araçlar ------------------------------------------------------------------
fetch_tools() {
  mkdir -p vendor-win
  $UPDATE && rm -f vendor-win/*.exe vendor-win/yt-dlp.version
  if [[ ! -f vendor-win/ffmpeg.exe ]]; then
    echo "→ ffmpeg.exe indiriliyor"
    local url="https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    curl -fSL --progress-bar -o vendor-win/ffmpeg.zip "$url"
    [[ "$(curl -fsSL "$url.sha256")" == "$(shasum -a 256 vendor-win/ffmpeg.zip | awk '{print $1}')" ]] \
      || { echo "ffmpeg sha256 uyuşmuyor!" >&2; exit 1; }
    unzip -joq vendor-win/ffmpeg.zip '*/bin/ffmpeg.exe' -d vendor-win && rm vendor-win/ffmpeg.zip
  fi
  if [[ ! -f vendor-win/yt-dlp.exe ]]; then
    echo "→ yt-dlp.exe indiriliyor"
    curl -fSL --progress-bar -o vendor-win/yt-dlp.exe https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe
    rm -f vendor-win/yt-dlp.version
  fi
  if [[ ! -f vendor-win/yt-dlp.version ]]; then
    # .exe burada çalışmadığı için sürüm, en son yayının etiketinden okunur
    curl -fsSI https://github.com/yt-dlp/yt-dlp/releases/latest | awk -F/ 'tolower($1) ~ /^location:/ {print $NF}' \
      | tr -d '\r\n' > vendor-win/yt-dlp.version
  fi
  if [[ ! -f vendor-win/deno.exe ]]; then
    echo "→ deno.exe indiriliyor"
    curl -fSL --progress-bar -o vendor-win/deno.zip https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip
    unzip -oq vendor-win/deno.zip -d vendor-win && rm vendor-win/deno.zip
  fi
  if [[ ! -f vendor-win/cacert.pem ]]; then
    # Güvenilir sertifika listesi (Mozilla, curl projesi yayımlar); kesit indirirken ffmpeg kullanır
    echo "→ cacert.pem indiriliyor"
    curl -fsSL -o vendor-win/cacert.pem https://curl.se/ca/cacert.pem
    [[ "$(curl -fsSL https://curl.se/ca/cacert.pem.sha256 | awk '{print $1}')" == "$(shasum -a 256 vendor-win/cacert.pem | awk '{print $1}')" ]] \
      || { rm -f vendor-win/cacert.pem; echo "cacert.pem sha256 uyuşmuyor!" >&2; exit 1; }
  fi
  [[ -s vendor-win/yt-dlp.version ]] || { echo "yt-dlp sürümü okunamadı" >&2; exit 1; }
}

# PNG'lerden çok boyutlu .ico (PNG gömülü ICO; Windows Vista ve sonrası destekler)
make_ico() {
  python3 - "$@" <<'EOF'
import struct, sys
out, *pngs = sys.argv[1:]
images = [open(p, "rb").read() for p in pngs]
header = struct.pack("<HHH", 0, 1, len(images))
offset = 6 + 16 * len(images)
entries, data = b"", b""
for img in images:
    w, h = struct.unpack(">II", img[16:24])
    entries += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(img), offset + len(data))
    data += img
open(out, "wb").write(header + entries + data)
EOF
}

# --- Bir kurum ----------------------------------------------------------------
build_brand() {
  local id="$1"
  # shellcheck disable=SC1090
  source "brands/$id/brand.conf"
  local out="build/windows/$id" assets="build/windows/$id/assets"
  echo
  echo "━━ $APP_NAME (Windows)"
  mkdir -p "$assets"

  echo "→ İkonlar"
  ICON_BG_TOP="$ICON_BG_TOP" ICON_BG_BOTTOM="$ICON_BG_BOTTOM" ICON_GLOSS="$ICON_GLOSS" \
  LOGO_SCALE="$LOGO_SCALE" BADGE_SIZE="$BADGE_SIZE" BADGE_Y="$BADGE_Y" \
  BADGE_FILL="$BADGE_FILL" BADGE_GLYPH="$BADGE_GLYPH" \
    swift app/tools/render_assets.swift "$LOGO" "$assets" >/dev/null
  local set="$assets/AppIcon.iconset"
  make_ico "$assets/icon.ico" "$set/icon_16x16.png" "$set/icon_32x32.png" "$set/icon_32x32@2x.png" \
    "$set/icon_128x128.png" "$set/icon_256x256.png"

  # windows/src'yi bu kurum için hazırla (bu dosyalar üretilir, git'e girmez)
  local appId="${BUNDLE_ID/org./org.}.windows"
  cat > windows/src/brand.json <<EOF
{
  "appName": "$APP_NAME",
  "tagline": "$TAGLINE",
  "helpFooter": "$HELP_FOOTER",
  "urlPlaceholder": "$URL_PLACEHOLDER",
  "supportFolder": "$SUPPORT_DIR",
  "appId": "$appId",
  "accent": "$ACCENT",
  "accentDark": "$ACCENT_DARK",
  "titleWidth": $TITLE_WIDTH
}
EOF
  mkdir -p windows/src/renderer/fonts
  cp "brands/$id/Fonts/$FONT_FILE" windows/src/renderer/fonts/brand.ttf
  cp "$set/icon_128x128@2x.png" windows/src/renderer/icon.png
  $STAGE_ONLY && { echo "✓ windows/src $APP_NAME için hazırlandı"; return; }

  echo "→ Kurulum dosyası derleniyor"
  local root; root="$(pwd)"
  cat > "$out/electron-builder.json" <<EOF
{
  "appId": "$appId",
  "productName": "$APP_NAME",
  "copyright": "$APP_NAME",
  "artifactName": "$DMG_NAME-Setup.\${ext}",
  "directories": { "output": "$root/$out/dist" },
  "files": ["src/**/*", "package.json"],
  "extraResources": [
    { "from": "$root/vendor-win", "to": "bin", "filter": ["*.exe", "yt-dlp.version", "cacert.pem"] },
    { "from": "$root/brands/$id/Fonts", "to": "licenses", "filter": ["*.txt"] }
  ],
  "asar": true,
  "compression": "normal",
  "win": {
    "target": [{ "target": "nsis", "arch": ["x64"] }],
    "icon": "$root/$assets/icon.ico"
  },
  "nsis": {
    "oneClick": true,
    "perMachine": false,
    "runAfterFinish": true,
    "createDesktopShortcut": true,
    "createStartMenuShortcut": true,
    "shortcutName": "$APP_NAME",
    "uninstallDisplayName": "$APP_NAME",
    "installerIcon": "$root/$assets/icon.ico",
    "uninstallerIcon": "$root/$assets/icon.ico",
    "language": "1055",
    "installerLanguages": ["tr_TR"]
  }
}
EOF
  rm -rf "$out/dist"
  (cd windows && npx electron-builder --win --x64 --config "$root/$out/electron-builder.json" --publish never) \
    > "$out/build.log" 2>&1 || { tail -30 "$out/build.log"; exit 1; }
  mkdir -p build/windows
  mv "$out/dist/$DMG_NAME-Setup.exe" "build/windows/"
  echo "✓ build/windows/$DMG_NAME-Setup.exe ($(du -h "build/windows/$DMG_NAME-Setup.exe" | cut -f1))"
}

fetch_tools
for id in "${BRANDS[@]}"; do
  build_brand "$id"
done
