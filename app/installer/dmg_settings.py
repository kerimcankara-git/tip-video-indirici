# dmgbuild ayarları: DMG penceresinin görünümü.
# build_app.sh şöyle çağırır:
#   dmgbuild -s app/installer/dmg_settings.py -D app=<.app> -D background=<.tiff> [-D guide=<.pdf>] "<Birim adı>" <çıktı.dmg>
# Simge konumları app/installer/background.html'deki çizimle aynı olmalı.
import os.path
from unicodedata import normalize

app = defines["app"]                         # noqa: F821 (dmgbuild tarafından verilir)
app_name = os.path.basename(app)
guide = defines.get("guide")                 # noqa: F821


def finder_name(name):
    # HFS+ dosya adlarını ayrıştırılmış (NFD) biçimde saklar: "İ" -> "I" + U+0307.
    # .DS_Store'daki anahtar bununla birebir eşleşmezse Finder simge konumunu yok sayar.
    return normalize("NFD", name)

files = [app] + ([guide] if guide else [])
symlinks = {"Applications": "/Applications"}
# Not: hide_extensions KULLANMAYIN. Uygulama klasörüne com.apple.FinderInfo ekliyor; bu, kod imzasını
# geçersiz kılıyor ve indirilen DMG'den kurulan uygulama başka Mac'lerde "açılamıyor" hatası veriyor
# (Gatekeeper "Yine de Aç" seçeneğini de sunmuyor). Finder .app uzantısını zaten gizler.

format = "UDZO"
filesystem = "HFS+"
background = defines["background"]           # noqa: F821

# 760×620 içerik alanı + başlık çubuğu. Finder pencereyi daha büyük açarsa arka plan
# görseli zaten daha geniş üretildiği için boşluk kalmaz (bkz. background.html).
window_rect = ((160, 100), (760, 648))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 96
text_size = 13
icon_locations = {
    finder_name(app_name): (200, 160),
    "Applications": (560, 160),
}
if guide:
    icon_locations[finder_name(os.path.basename(guide))] = (660, 540)
