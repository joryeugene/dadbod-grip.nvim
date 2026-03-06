#!/usr/bin/env python3
"""
dadbod-grip.nvim mascot: pixel art animated flexing data-dad.
Run: python3 assets/gen_mascot.py
"""
from PIL import Image

# --- Palette ---
_ = (0,   0,   0,   0)
K = (18,  12,  38,  255)   # dark outline
S = (244, 162, 97,  255)   # skin warm amber
D = (195, 110, 52,  255)   # fist / skin shadow
R = (225, 90,  90,  255)   # rosy cheek
N = (88,  48,  140, 255)   # beanie purple (uniform body + cuff use same hue)
NL = (130, 80, 190, 255)   # beanie cuff lighter stripe
Y = (255, 220, 60,  255)   # pom-pom yellow
T = (232, 90,  70,  255)   # shirt coral/orange
V = (255, 150, 60,  255)   # shirt stripe warm yellow
P = (138, 100, 42,  255)   # tan pants
Z = (45,  28,  8,   255)   # belt dark
X = (75,  50,  15,  255)   # shoe
W = (255, 255, 255, 255)   # white teeth + letters
Q = (230, 120, 130, 255)   # tongue pink

PALETTE = {
    '.': _, 'K': K, 'S': S, 'D': D, 'R': R,
    'N': N, 'L': NL, 'Y': Y,
    'T': T, 'V': V,
    'P': P, 'Z': Z, 'X': X,
    'W': W, 'Q': Q,
}

# Wider canvas so arms fit comfortably inside
W_PX, H_PX = 36, 48
SCALE = 8  # → 288 × 384

def r(left, content, right=None):
    rp = right if right is not None else (W_PX - left - len(content))
    s = '.' * left + content + '.' * rp
    assert len(s) == W_PX, f"len={len(s)} (need {W_PX}): left={left} content={len(content)}: {repr(content)}"
    return s

def box(lc, inner):
    return r(lc, 'K' + inner + 'K')

def shirt(width):
    return ''.join('V' if i % 3 == 2 else 'T' for i in range(width))

# --- D.B.G pixel font 4×5 ---
_F = {
    'D': ["###.", "#..#", "#..#", "#..#", "###."],
    'B': ["###.", "#..#", "###.", "#..#", "###."],
    'G': [".###", "#...", "#.##", "#..#", ".###"],
}
def dbg_rows(bg='T'):
    return [
        (_F['D'][i] + bg + _F['B'][i] + bg + _F['G'][i])
        .replace('#', 'W').replace('.', bg)
        for i in range(5)
    ]   # each row = 14 chars wide

DBG = dbg_rows()

def belly_text(inner, txt):
    pad = (inner - len(txt)) // 2
    return 'T' * pad + txt + 'T' * (inner - len(txt) - pad)

# -------------------------------------------------------
# BASE grid: 36 wide × 48 tall
# Layout centres on col 18.
#   Beanie:    box(12, N*12) → K at cols 12,25  (14 wide)
#   Head:      box( 8, S*18) → K at cols  8,27  (20 wide)
#   Shoulders: box( 7, T*20) → K at cols  7,28  (22 wide)
#   Peak belly:box( 4, T*26) → K at cols  4,31  (28 wide)
#   Belt:      box( 7, Z*20)
#   Pants:     box( 8, P*18)
#   Legs:  r(8, 'KPPPK' + '.'*11 + 'KPPPK')   → 36 wide
# -------------------------------------------------------
BASE = []

# ROWS 0-2: air above pom-pom
for _ in range(3):
    BASE.append(r(0, '.' * W_PX))

# ROW 3: pom-pom (K outline + Y fill, 4 wide)
BASE.append(r(17, 'K' + 'YY' + 'K'))          # 3  pom-pom: K at 17, YY at 18-19, K at 20

# ROW 4: K top of beanie (uniform: 14 wide, cols 12-25)
BASE.append(r(12, 'K' * 14))                   # 4

# ROWS 5-7: beanie body (14 wide, same as K top)
for _ in range(3):
    BASE.append(box(12, 'N' * 12))             # 5-7

# ROW 8: beanie cuff: SAME WIDTH as body (not wider!)
BASE.append(box(12, 'L' * 12))                 # 8

# ROW 9: K bottom of beanie (same width)
BASE.append(r(12, 'K' * 14))                   # 9

# ROWS 10-20: Head (box at col 8, inner 18)
#  inner layout (positions 0-17):
#    left eye:   positions 3-5  (3 wide)
#    right eye:  positions 12-14 (3 wide)
#    left cheek: positions 1-3
#    right cheek: positions 14-16
BASE.append(box(8, 'S' * 18))                  # 10 forehead
BASE.append(box(8, 'S' * 18))                  # 11

# Row 12: eyebrows: 2px wide, angled inward (slightly closer to center)
BASE.append(box(8, 'SSS' + 'KK' + 'S' * 8 + 'KK' + 'SSS'))   # 12 brows

BASE.append(box(8, 'S' * 18))                  # 13 gap between brow & eye

# Rows 14-15: eyes (3×2 big cartoon squares)
_eye    = 'SSS' + 'KKK' + 'SS' * 3 + 'KKK' + 'SSS'  # 3+3+6+3+3 = 18
_eye_hi = 'SSS' + 'WKK' + 'SS' * 3 + 'WKK' + 'SSS'  # top row: W highlight top-left of each eye
BASE.append(box(8, _eye_hi))                    # 14 eye top (with white highlight)
BASE.append(box(8, _eye))                       # 15 eye bottom

# Row 16: BIG rosy cheeks (3px wide blush under eyes)
BASE.append(box(8, 'S' + 'RRR' + 'S' * 8 + 'RRR' + 'SS'))    # 16

BASE.append(box(8, 'S' * 18))                  # 17 mid-face / nose

# Row 18: MEGA GRIN (full teeth)
BASE.append(box(8, 'S' + 'W' * 16 + 'S'))      # 18

# Row 19: tongue peeking out (Q = pink, centred)
BASE.append(r(10, 'KK' + 'S' * 4 + 'QQQ' + 'S' * 4 + 'KK'))  # 19

# Row 20: neck
BASE.append(r(12, 'K' * 12))                   # 20

# ROWS 21-22: Shoulders
BASE.append(box(7, shirt(20)))                  # 21
BASE.append(box(7, shirt(20)))                  # 22

# ROWS 23-25: Chest
for _ in range(3):
    BASE.append(box(7, shirt(20)))              # 23-25

# ROWS 26-33: BELLY: widens for dadbod, then DBG text
BASE.append(box(6, shirt(22)))                  # 26 belly +1
BASE.append(box(5, shirt(24)))                  # 27 belly +2
BASE.append(box(4, shirt(26)))                  # 28 peak belly (+3 each side)

for i in range(5):
    BASE.append(box(4, belly_text(26, DBG[i]))) # 29-33  DBG text

BASE.append(box(4, shirt(26)))                  # 34 belly below text
BASE.append(box(5, shirt(24)))                  # 35 belly tapers
BASE.append(box(6, shirt(22)))                  # 36 belly bottom

# ROWS 37-38: Belt
BASE.append(box(7, 'Z' * 20))                  # 37
BASE.append(box(7, 'Z' * 20))                  # 38

# ROWS 39-40: Pants
BASE.append(box(8, 'P' * 18))                  # 39
BASE.append(box(8, 'P' * 18))                  # 40

# ROWS 41-44: Legs split
for _ in range(4):
    BASE.append(r(8, 'K' + 'P'*3 + 'K' + '.'*11 + 'K' + 'P'*3 + 'K'))  # 41-44

# ROWS 45-46: Shoes
BASE.append(r(8, 'K' + 'X'*3 + 'K' + '.'*11 + 'K' + 'X'*3 + 'K'))  # 45
BASE.append(r(8, 'K' + 'X'*4 + 'K' + '.'*9  + 'K' + 'X'*4 + 'K'))  # 46

while len(BASE) < H_PX:
    BASE.append(r(0, '.' * W_PX))

assert len(BASE) == H_PX, f"BASE has {len(BASE)} rows, expected {H_PX}"

# -------------------------------------------------------
def grid_to_pixels(grid):
    px = {}
    for ri, row in enumerate(grid):
        for ci, ch in enumerate(row):
            px[(ci, ri)] = PALETTE.get(ch, _)
    return px

def render(px_map):
    img = Image.new("RGBA", (W_PX * SCALE, H_PX * SCALE), (0, 0, 0, 0))
    pxl = img.load()
    for (c, ri), color in px_map.items():
        if 0 <= c < W_PX and 0 <= ri < H_PX and color[3] > 0:
            x0, y0 = c * SCALE, ri * SCALE
            for dx in range(SCALE):
                for dy in range(SCALE):
                    pxl[x0 + dx, y0 + dy] = color
    return img

# -------------------------------------------------------
# Arms: L-shaped flex: elbow OUT to side, forearm points INWARD toward face
#
# Shoulder at col 7, row 21.
# Phase 3 (full flex): elbow at col 2, forearm goes right to col 6, fist near face.
# The fist ends at col 6-7 (face K border is at col 8): clearly beside the head.
# -------------------------------------------------------
def thick_px(points, fill, t=2):
    result = {}
    for (c, ri) in points:
        for dc in range(-1, t + 1):
            for dr in range(-1, t + 1):
                result[(c + dc, ri + dr)] = K
    for (c, ri) in points:
        for dc in range(t):
            for dr in range(t):
                result[(c + dc, ri + dr)] = fill
    return result

def left_arm(phase):
    # Shoulder at col ~7, row 21.
    # Classic bicep flex: upper arm diagonal out+up to elbow,
    # forearm bends UPWARD from elbow, fist raised to brow level.
    # Elbow sticks out LEFT; fist ends high beside face (col 5-6, row 12).
    arms = [
        # 0: arm at rest, hanging slightly outward
        dict(upper=[(7, 21), (6, 22), (5, 22)],
             fore =[(5, 22), (4, 23), (3, 23)],
             fist =[(3, 22)]),
        # 1: arm rising: elbow out, fist at shoulder height
        dict(upper=[(6, 21), (5, 21), (4, 20), (3, 20)],
             fore =[(3, 20), (3, 19), (4, 18)],
             fist =[(4, 17)]),
        # 2: elbow clearly out, fist at chin/cheek height
        dict(upper=[(6, 21), (5, 20), (4, 19), (3, 18), (2, 17)],
             fore =[(2, 17), (2, 16), (3, 15)],
             fist =[(3, 14), (4, 14)]),
        # 3: FULL FLEX ᕦ: elbow out at chest, forearm UP, fist at brow
        dict(upper=[(6, 21), (5, 20), (4, 19), (3, 18), (2, 17)],
             fore =[(2, 17), (2, 16), (3, 15), (4, 14), (5, 13)],
             fist =[(5, 12), (6, 12)]),
    ]
    a = arms[phase]
    seg = {}
    seg.update(thick_px(a['upper'], S))
    seg.update(thick_px(a['fore'],  S))
    seg.update(thick_px(a['fist'],  D))
    return seg

def mirror_arm(seg):
    return {(W_PX - 1 - c, ri): color for (c, ri), color in seg.items()}

def wince_face():
    """Pixel overrides for the subtle squint at peak flex (phase 3 only)."""
    result = {}
    # Close just the bottom eye row — top stays open, grin unchanged
    _eye_bot_closed = 'S' * 18
    for ci, ch in enumerate(box(8, _eye_bot_closed)):
        result[(ci, 15)] = PALETTE[ch]
    return result

# -------------------------------------------------------
base_px = grid_to_pixels(BASE)
phases = [0, 1, 2, 3, 2, 1]
frames = []
grunt_px = wince_face()
for phase in phases:
    al = left_arm(phase)
    ar = mirror_arm(al)
    px = {**base_px, **ar, **al}
    if phase == 3:
        px = {**px, **grunt_px}
    frames.append(render(px))

out = "assets/mascot.gif"
durations = [160, 160, 200, 320, 200, 160]  # phase 3 (peak flex) holds longer
frames[0].save(
    out, save_all=True, append_images=frames[1:],
    optimize=True, loop=0, duration=durations, disposal=2,
)
print(f"Saved {out}  ({W_PX * SCALE}×{H_PX * SCALE}px, {len(frames)} frames)")
