# Логотип Basic Caster: буква «B» фирменным шрифтом (Unbounded SemiBold)
# на фирменном лаймовом круге. Контур буквы берётся прямо из шрифта.
import os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen

_FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'assets', 'fonts', 'Unbounded-SemiBold.ttf')
LIME = '#C5F52E'
INK = '#161616'


def _glyph():
    font = TTFont(_FONT)
    gs = font.getGlyphSet()
    name = font.getBestCmap()[ord('B')]
    pen = SVGPathPen(gs)
    gs[name].draw(pen)
    bounds = BoundsPen(gs)
    gs[name].draw(bounds)
    return pen.getCommands(), bounds.bounds


def logo(bg=True, mono=False, b=None, scale=1.0, outline_slice=False):
    """SVG 765×765. bg — лаймовый круг; mono — белая буква без фона
    (значки, которые система красит сама). [b], [outline_slice] оставлены
    для совместимости со старым вызовом и не используются."""
    path, (x0, y0, x1, y1) = _glyph()
    w, h = x1 - x0, y1 - y0
    # Высота буквы — половина круга (с [scale]), по центру; ось Y шрифта — вверх.
    k = 765 * 0.5 * scale / h
    tx = 382.5 - (x0 + w / 2) * k
    ty = 382.5 + (y0 + h / 2) * k
    color = '#FFFFFF' if mono else INK
    out = ['<svg width="765" height="765" viewBox="0 0 765 765" fill="none" xmlns="http://www.w3.org/2000/svg">']
    if bg and not mono:
        out.append(f'<circle cx="382.5" cy="382.5" r="382.5" fill="{LIME}"/>')
    out.append(f'<path transform="translate({tx:.2f} {ty:.2f}) scale({k:.5f} {-k:.5f})" d="{path}" fill="{color}"/>')
    out.append('</svg>')
    return '\n'.join(out)
