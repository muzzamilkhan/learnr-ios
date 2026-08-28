"""Build the 1024x1024 iOS app icon from the web app's badge master.

Source: `public/logo-mark.png` in `muzzamilkhan/learnr` - 512x512, the badge cut
out of `public/logo.PNG` with the page flood-filled to transparency. The L22
answer names it as the badge-only master; `src/app/icon.png` (192) is a downscale
of the same cut and is NOT what to build from.

Four things this does, each deliberate.

**The grape field is bled to the full square.** The badge carries its own
rounded-square silhouette - a superellipse, n~2.7, filling 86% of its box - and
iOS masks an icon with a squarer shape, n~5 at ~95%. Composite the badge as-is
and it is rounded twice, with a ring of background showing at every corner. So
the field is extended past the badge's own edge to fill the square and Apple's
mask is the only rounding. The artwork is untouched: it keeps its size, its
position and its own edges. Only the purple behind it grows.

**The field is measured, not guessed.** For each row of the master, the field
colour is the median of the opaque badge pixels 3-12px inside the silhouette on
both flanks. That tracks the badge's real vertical gradient (about #5547E4 at
the top easing to #4F40D4 where the book starts) rather than a two-stop ramp
fitted by eye - a ramp that is even slightly off leaves a seam along the join,
which is exactly how the first two attempts at this failed. Below the book the
measured colour is the book itself, so the last clean row is held instead.

**The badge's rim is dissolved into the field.** This is the part that took
three attempts. Profiling inward from the silhouette on any clean row gives the
same three pixels every time - a pale page leftover (239,238,250), a light lilac
blend (189,184,249), then the badge's own edge darkening (42,34,203) - before
true field at (80,60,227). All three were drawn to meet the white page. Leave
them and the icon wears a pale outline; recolour only the transparent ones and
the dark third pixel becomes a dark outline instead. So RIM px of the silhouette
are taken as field, and the rim is gone rather than merely recoloured.

The band is measured from the master, not from the mask: `edge_depth`
flood-fills inward from the transparent surround, so the depth is honest around
the book's overhang too, where the silhouette is not a superellipse at all.

**The result is opaque, with no alpha channel.** Apple rejects an App Store icon
carrying one, and iOS composites its mask over a square - a transparent PNG comes
out black under it. It is the same reason `src/app/apple-icon.png` is the one web
asset that keeps an opaque background.

`logo-mark-512.png` beside this script is that master, vendored: the web side
holds no script that cuts it (`8a0c891` added four PNGs and no tooling), so the
input is the asset, not a build step. Re-vendor it if the mark is redrawn.

Regenerate, from the repository root:

    python3 tools/appicon/make-app-icon.py

which rewrites LearnrApp/LearnrApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
Stock python3 only - there is no PIL or ImageMagick on this machine, so the PNG
read/write lives in `pnglib.py` beside this.
"""
import os, sys, math, statistics

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pnglib

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "logo-mark-512.png")
OUT = os.path.join(HERE, "..", "..", "LearnrApp", "LearnrApp",
                   "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")
S = 1024

# Rows below this are book, not field: the median stops measuring the badge.
FIELD_LAST_ROW = 384
# A row must be at least this wide for its flanks to be clear of the corner
# arcs. Narrower rows sample the rim, not the field, and read pale lilac.
FIELD_MIN_WIDTH = 300
# How deep the badge's white-facing rim runs, in master pixels. Profiled at
# rows 120/200/256/300: pale leftover, lilac blend, dark edge, then field.
RIM = 3

def measure_field(w, h, px):
    """The badge's own vertical gradient, one colour per master row."""
    alpha = lambda x, y: px[((y*w)+x)*4+3]
    rgb = lambda x, y: (px[((y*w)+x)*4], px[((y*w)+x)*4+1], px[((y*w)+x)*4+2])

    rows = [None]*h
    for y in range(h):
        opaque = [x for x in range(w) if alpha(x, y) >= 255]
        # Near the top and bottom the badge is a narrow arc, and a band 3-12px
        # inside it is still the white-facing rim - sampling there gives a pale
        # lilac, which then back-fills upward as the field and paints the whole
        # top edge with it. Only rows wide enough to have real field on both
        # flanks are measured; the rest inherit.
        if len(opaque) < FIELD_MIN_WIDTH:
            continue
        lx, rx = min(opaque), max(opaque)
        band = [rgb(x, y)
                for x in list(range(lx+3, lx+13)) + list(range(rx-12, rx-2))
                if 0 <= x < w and alpha(x, y) >= 255]
        if len(band) >= 8:
            rows[y] = tuple(statistics.median([c[i] for c in band]) for i in range(3))

    # Hold the last measured colour past the book, and the first back to the top.
    clean = [y for y in range(min(FIELD_LAST_ROW, h)) if rows[y] is not None]
    first, last = clean[0], clean[-1]
    for y in range(h):
        if y < first:            rows[y] = rows[first]
        elif y > last:           rows[y] = rows[last]
        elif rows[y] is None:    rows[y] = rows[y-1]

    # Smooth out the median's row-to-row jitter; the gradient is monotone-ish
    # and a 9-row box leaves no step visible at 1024.
    k = 4
    return [tuple(sum(rows[min(max(y+d, 0), h-1)][i] for d in range(-k, k+1))/(2*k+1)
                  for i in range(3))
            for y in range(h)]

def edge_depth(w, h, px):
    """Pixels from each pixel to the transparent surround, breadth-first.

    Measured rather than derived from the fitted superellipse: around the book's
    overhang the silhouette is not that curve, and a rim band that ignores it
    would cut into the pages.
    """
    INF = 1 << 30
    dist = [INF]*(w*h)
    frontier = []
    for i in range(w*h):
        if px[i*4+3] == 0:
            dist[i] = 0
            frontier.append(i)
    # The badge is clipped flush at the canvas edge in places - across the top
    # around x=240-260, down the left at y=240-256, along the bottom - and those
    # clipped pixels are near-opaque but pale (a=254, (238,236,245)): the same
    # white-facing rim, merely cut off before it faded out. Seeding every border
    # pixel at depth 1 regardless of its alpha puts them inside the band too.
    # Without this the arcs come out clean and the flush edges keep a light
    # fringe, which is worse than a uniform one because it looks like a bug.
    for y in range(h):
        for x in (0, w-1):
            i = y*w + x
            if dist[i] > 1: dist[i] = 1; frontier.append(i)
    for x in range(w):
        for y in (0, h-1):
            i = y*w + x
            if dist[i] > 1: dist[i] = 1; frontier.append(i)

    while frontier:
        nxt = []
        for i in frontier:
            d = dist[i] + 1
            if d > RIM: continue
            y, x = divmod(i, w)
            for ny, nx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)):
                if 0 <= nx < w and 0 <= ny < h:
                    j = ny*w + nx
                    if dist[j] > d:
                        dist[j] = d; nxt.append(j)
        frontier = nxt
    return dist

def cubic(t):
    """Catmull-Rom (Mitchell a=-0.5). The slight overshoot keeps a 2x blow-up crisp."""
    t = abs(t)
    if t < 1: return 1.5*t**3 - 2.5*t**2 + 1
    if t < 2: return -0.5*t**3 + 2.5*t**2 - 4*t + 2
    return 0.0

def main():
    w, h, px = pnglib.read_rgba(SRC)
    field = measure_field(w, h, px)
    depth = edge_depth(w, h, px)

    # Everything within RIM of the silhouette becomes opaque field; the rest
    # keeps the artist's colour. Premultiplying afterwards is then a formality -
    # nothing transparent is left to bleed - but it keeps the resample correct
    # for the book's overhanging edge, which is genuine artwork against nothing.
    pm = [0.0]*(w*h*4)
    for y in range(h):
        fr, fg, fb = field[y]
        for x in range(w):
            i = y*w + x
            if depth[i] <= RIM:
                r, g, b, a = fr, fg, fb, 1.0
            else:
                r, g, b = px[i*4], px[i*4+1], px[i*4+2]
                a = px[i*4+3]/255.0
            pm[i*4+0] = r*a; pm[i*4+1] = g*a
            pm[i*4+2] = b*a; pm[i*4+3] = a

    # The scale is uniform, so every row reuses one set of column taps.
    scale = w/float(S)
    taps = []
    for x in range(S):
        fx = (x+0.5)*scale - 0.5
        ix = math.floor(fx)
        ws = [(min(max(ix+d, 0), w-1), cubic(fx-(ix+d))) for d in range(-1, 3)]
        tot = sum(v for _, v in ws) or 1.0
        taps.append([(i, v/tot) for i, v in ws])

    out = bytearray(S*S*4)
    for y in range(S):
        fy = (y+0.5)*scale - 0.5
        iy = math.floor(fy)
        wys = [(min(max(iy+d, 0), h-1), cubic(fy-(iy+d))) for d in range(-1, 3)]
        tot = sum(v for _, v in wys) or 1.0
        wys = [(i, v/tot) for i, v in wys]

        fr, fg, fb = field[min(max(int((y+0.5)*scale), 0), h-1)]

        for x in range(S):
            r = g = b = a = 0.0
            for yy, wy in wys:
                if wy == 0.0: continue
                base = yy*w
                for xx, wx in taps[x]:
                    ww = wy*wx
                    if ww == 0.0: continue
                    o = (base+xx)*4
                    r += pm[o]*ww; g += pm[o+1]*ww
                    b += pm[o+2]*ww; a += pm[o+3]*ww
            a = min(max(a, 0.0), 1.0)

            # Badge over the bled field. r,g,b are premultiplied, so this is
            # source-over against an opaque backdrop in one step.
            o = (y*S+x)*4
            out[o]   = max(0, min(255, int(round(r + fr*(1.0-a)))))
            out[o+1] = max(0, min(255, int(round(g + fg*(1.0-a)))))
            out[o+2] = max(0, min(255, int(round(b + fb*(1.0-a)))))
            out[o+3] = 255

    pnglib.write_rgb(OUT, S, S, out, alpha=False)
    print(f"wrote {os.path.normpath(OUT)}")

if __name__ == "__main__":
    main()
