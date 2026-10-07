# Логотип Basic Caster из точных дуг и прямых (без ломаных): кольцо-сектор и выдвинутый кусок.
import math, io
import cairosvg
from PIL import Image, ImageDraw, ImageFont

def v(a): r=math.radians(a); return (math.cos(r), math.sin(r))
def add(p,q,k=1): return (p[0]+k*q[0], p[1]+k*q[1])
def sub(p,q): return (p[0]-q[0], p[1]-q[1])
def dot(p,q): return p[0]*q[0]+p[1]*q[1]
def norm(p): return math.hypot(*p)
def proj(c,p,d): return add(p,d,dot(sub(c,p),d))
def inter(p1,d1,p2,d2):
    det=d1[0]*(-d2[1])-d1[1]*(-d2[0]); w=sub(p2,p1)
    u=(w[0]*(-d2[1])-w[1]*(-d2[0]))/det
    return add(p1,d1,u)
def line_circle_fillet(p,d,n,O,Ra,r):
    q=add(p,n,r); w=sub(q,O)
    B=2*dot(w,d); Cc=dot(w,w)-(Ra-r)**2
    t=(-B+math.sqrt(B*B-4*Cc))/2
    c=add(q,d,t)
    return c, proj(c,p,d), add(O, sub(c,O), Ra/norm(sub(c,O)))
def f(p): return f'{p[0]:.2f} {p[1]:.2f}'

def contour(O,Ra,A,B,apex_concave,r_apex,r_arc,large):
    """A, B: (точка, направление наружу, внутренняя нормаль). Обход: наружу по A, по дуге, внутрь по B."""
    (pA,dA,nA),(pB,dB,nB)=A,B
    s=-1 if apex_concave else 1
    ca=inter(add(pA,nA,s*r_apex),dA,add(pB,nB,s*r_apex),dB)
    a0=proj(ca,pA,dA); b0=proj(ca,pB,dB)
    _,a1,a2=line_circle_fillet(pA,dA,nA,O,Ra,r_arc)
    _,b1,b2=line_circle_fillet(pB,dB,nB,O,Ra,r_arc)
    ap_sweep=0 if apex_concave else 1
    return (f'M{f(a0)} L{f(a1)} A{r_arc} {r_arc} 0 0 1 {f(a2)} '
            f'A{Ra} {Ra} 0 {large} 1 {f(b2)} A{r_arc} {r_arc} 0 0 1 {f(b1)} '
            f'L{f(b0)} A{r_apex} {r_apex} 0 0 {ap_sweep} {f(a0)}Z')

# Цвета иконки (вариант с лаймовым фоном, октябрь 2026): фон — фирменный
# лаймовый, знак тёмный, крупнее и толще прежнего, чтобы иконка не казалась
# меньше соседних.
LIME, INK = '#C5F52E', '#161616'

def logo(mono=False, outline_slice=False, shift=(5,8.2), center=(1.5,-0.7), bg=True,
         b=52, scale=1.10, bg_color=LIME, ring=INK, slice_color=INK):
    R, rc, rf, ri = 282.5, 28, 30, 12
    O=(382.5+center[0], 382.5+center[1])
    # кольцо: край A — луч на 30°, край B — луч вверх
    eA=(O, v(30), v(120)); eB=(O, v(-90), v(180))
    outer=contour(O,R,eA,eB,True,rf,rc,1)
    iA=(add(O,v(120),b), v(30), v(120)); iB=(add(O,v(180),b), v(-90), v(180))
    inner=contour(O,R-b,iA,iB,True,rf+b,ri,1)
    # кусок
    Os=(432.5+shift[0]+center[0], 342.5+shift[1]+center[1]); Rs=224.5
    sA=(Os, v(-90), v(0)); sB=(Os, v(30), v(-60))
    sl=contour(Os,Rs,sA,sB,False,30,28,0)
    if outline_slice:
        sAi=(add(Os,v(0),b), v(-90), v(0)); sBi=(add(Os,v(-60),b), v(30), v(-60))
        sl+=' '+contour(Os,Rs-b,sAi,sBi,False,8,ri,0)
    ring_fill = 'white' if mono else ring
    slice_fill = 'white' if mono else slice_color
    back=f'<circle cx="382.5" cy="382.5" r="382.5" fill="{bg_color}"/>\n' if bg else ''
    g = f'<g transform="translate(382.5 382.5) scale({scale}) translate(-382.5 -382.5)">' if scale != 1 else '<g>'
    return (f'<svg width="765" height="765" viewBox="0 0 765 765" fill="none" xmlns="http://www.w3.org/2000/svg">\n{back}{g}\n'
            f'<path d="{outer} {inner}" fill="{ring_fill}" fill-rule="evenodd"/>\n'
            f'<path d="{sl}" fill="{slice_fill}" fill-rule="evenodd"/>\n</g>\n</svg>\n')

