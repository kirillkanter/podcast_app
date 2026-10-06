# Генерирует иконки из tool/icons/logo_source.svg: python3 tool/icons/make_icons.py .
# Нужны: pip install cairosvg pillow
import io, os, re, sys
import cairosvg
from PIL import Image
repo = sys.argv[1]
src = open(f'{repo}/tool/icons/logo_source.svg').read()
# Без crispEdges кривые сглаживаются: иначе на маленьких размерах «лесенка».
logo = src.replace(' shape-rendering="crispEdges"', '')
open(f'{repo}/tool/icons/logo.svg','w').write(logo)
open(f'{repo}/sync-server/server/icon.svg','w').write(logo)
glyph = re.sub(r'<circle cx="382.5" cy="382.5" r="382.5" fill="#292929"/>\n', '', logo)
def reframe(svg, vb):
    return re.sub(r'width="765" height="765" viewBox="0 0 765 765"', f'width="{vb[2]}" height="{vb[3]}" viewBox="{vb[0]} {vb[1]} {vb[2]} {vb[3]}"', svg, count=1)
# Адаптивная иконка: 108dp холст, видимая область ~72dp -> круг 765 = 72dp.
fg = reframe(glyph, (-191.25, -191.25, 1147.5, 1147.5))
# Монохромная/уведомление: без теней, всё белое.
flat = re.sub(r' filter="url\(#[^)]*\)"', '', glyph).replace('#C5F52E', 'white')
mono = reframe(flat, (-191.25, -191.25, 1147.5, 1147.5))
stat = reframe(flat.replace('stroke-width="25"', 'stroke-width="48"'), (62, 63, 640, 640))
def png(svg, size, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=path, output_width=size, output_height=size)
res = f'{repo}/tool/android/res'
for d, k in {'mdpi':1,'hdpi':1.5,'xhdpi':2,'xxhdpi':3,'xxxhdpi':4}.items():
    png(logo, int(48*k), f'{res}/mipmap-{d}/ic_launcher.png')
    png(fg, int(108*k), f'{res}/mipmap-{d}/ic_launcher_foreground.png')
    png(mono, int(108*k), f'{res}/mipmap-{d}/ic_launcher_monochrome.png')
    png(stat, int(24*k), f'{res}/drawable-{d}/ic_stat_bcaster.png')
os.makedirs(f'{res}/mipmap-anydpi-v26', exist_ok=True)
open(f'{res}/mipmap-anydpi-v26/ic_launcher.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''')
os.makedirs(f'{res}/values', exist_ok=True)
open(f'{res}/values/ic_launcher_background.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#292929</color>
</resources>
''')
# Windows: многоразмерный ico.
big = io.BytesIO(); cairosvg.svg2png(bytestring=logo.encode(), write_to=big, output_width=256, output_height=256)
os.makedirs(f'{repo}/tool/windows', exist_ok=True)
Image.open(big).save(f'{repo}/tool/windows/app_icon.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
# Превью для проверки

