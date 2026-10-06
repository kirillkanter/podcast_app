# Генерирует все иконки Basic Caster из геометрии логотипа (logo_geometry.py).
# Запуск из корня репозитория: python3 tool/icons/make_icons.py .
# Нужны: pip install cairosvg pillow
import io, os, re, sys
import cairosvg
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from logo_geometry import logo

repo = sys.argv[1] if len(sys.argv) > 1 else '.'

def reframe(svg, vb):
    x, y, w, h = vb
    return svg.replace('width="765" height="765" viewBox="0 0 765 765"',
                       f'width="{w}" height="{h}" viewBox="{x} {y} {w} {h}"', 1)

def png(svg, size, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=path, output_width=size, output_height=size)

full = logo()                                         # цветной, на тёмном круге
glyph = logo(bg=False)                                # без фона — передний слой адаптивной иконки
mono = logo(mono=True, outline_slice=True, bg=False)  # тематический значок: кусок обводкой
stat = logo(mono=True, bg=False)                      # строка состояния: кусок залит

open(f'{repo}/tool/icons/logo.svg', 'w').write(full)
open(f'{repo}/sync-server/server/icon.svg', 'w').write(full)

# Адаптивная иконка: холст 108dp, видимая область ~72dp -> круг 765 = 72dp.
adaptive = (-191.25, -191.25, 1147.5, 1147.5)
fg, mn = reframe(glyph, adaptive), reframe(mono, adaptive)
st = reframe(stat, (88, 88, 590, 590))                # знак почти на весь значок 24dp

res = f'{repo}/tool/android/res'
for d, k in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
    png(full, int(48 * k), f'{res}/mipmap-{d}/ic_launcher.png')
    png(fg, int(108 * k), f'{res}/mipmap-{d}/ic_launcher_foreground.png')
    png(mn, int(108 * k), f'{res}/mipmap-{d}/ic_launcher_monochrome.png')
    png(st, int(24 * k), f'{res}/drawable-{d}/ic_stat_bcaster.png')
os.makedirs(f'{res}/mipmap-anydpi-v26', exist_ok=True)
open(f'{res}/mipmap-anydpi-v26/ic_launcher.xml', 'w').write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''')
os.makedirs(f'{res}/values', exist_ok=True)
open(f'{res}/values/ic_launcher_background.xml', 'w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#292929</color>
</resources>
''')

# Логотип для бокового меню приложения.
png(full, 96, f'{repo}/assets/images/logo.png')

big = io.BytesIO()
cairosvg.svg2png(bytestring=full.encode(), write_to=big, output_width=256, output_height=256)
os.makedirs(f'{repo}/tool/windows', exist_ok=True)
Image.open(big).save(f'{repo}/tool/windows/app_icon.ico',
                     sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print('icons ok')
