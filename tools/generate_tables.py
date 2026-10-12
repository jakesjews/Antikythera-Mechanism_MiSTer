#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate the RTL tables from the reference model.

Writes rtl/am_tables.svh (constants, ROM functions), rtl/am_strings.sv (text
ROM) and rtl/am_font.sv (5x7 bitmap font with the Greek letters the dials
need). Run: python3 tools/generate_tables.py
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mechanism as M  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Character encoding: ASCII plus the Greek letters without a Latin look-alike.
# ---------------------------------------------------------------------------
GREEK_TO_LATIN = {'Α': 'A', 'Β': 'B', 'Ε': 'E', 'Ζ': 'Z', 'Η': 'H', 'Ι': 'I', 'Κ': 'K',
                  'Μ': 'M', 'Ν': 'N', 'Ο': 'O', 'Ρ': 'P', 'Τ': 'T', 'Υ': 'Y', 'Χ': 'X'}
EXTRA = {'Γ': 0x80, 'Δ': 0x81, 'Θ': 0x82, 'Λ': 0x83, 'Ξ': 0x84, 'Π': 0x85, 'Σ': 0x86,
         'Φ': 0x87, 'Ψ': 0x88, 'Ω': 0x89, 'ϛ': 0x8A, '°': 0x8B, 'ω': 0x8C, 'ρ': 0x8D,
         '☉': 0x8E, '☾': 0x8F, '→': 0x90, '←': 0x91, '•': 0x92}


def encode(text: str) -> list[int]:
    out = []
    for ch in text:
        if ch in GREEK_TO_LATIN:
            out.append(ord(GREEK_TO_LATIN[ch]))
        elif ch in EXTRA:
            out.append(EXTRA[ch])
        else:
            code = ord(ch)
            assert 32 <= code < 127, f'unsupported character {ch!r} in {text!r}'
            out.append(code)
    return out


FONT = {
    'A': '01110 10001 10001 11111 10001 10001 10001', 'B': '11110 10001 10001 11110 10001 10001 11110',
    'C': '01111 10000 10000 10000 10000 10000 01111', 'D': '11110 10001 10001 10001 10001 10001 11110',
    'E': '11111 10000 10000 11110 10000 10000 11111', 'F': '11111 10000 10000 11110 10000 10000 10000',
    'G': '01111 10000 10000 10111 10001 10001 01111', 'H': '10001 10001 10001 11111 10001 10001 10001',
    'I': '11111 00100 00100 00100 00100 00100 11111', 'J': '00111 00010 00010 00010 10010 10010 01100',
    'K': '10001 10010 10100 11000 10100 10010 10001', 'L': '10000 10000 10000 10000 10000 10000 11111',
    'M': '10001 11011 10101 10101 10001 10001 10001', 'N': '10001 11001 10101 10011 10001 10001 10001',
    'O': '01110 10001 10001 10001 10001 10001 01110', 'P': '11110 10001 10001 11110 10000 10000 10000',
    'Q': '01110 10001 10001 10001 10101 10010 01101', 'R': '11110 10001 10001 11110 10100 10010 10001',
    'S': '01111 10000 10000 01110 00001 00001 11110', 'T': '11111 00100 00100 00100 00100 00100 00100',
    'U': '10001 10001 10001 10001 10001 10001 01110', 'V': '10001 10001 10001 10001 10001 01010 00100',
    'W': '10001 10001 10001 10101 10101 10101 01010', 'X': '10001 10001 01010 00100 01010 10001 10001',
    'Y': '10001 10001 01010 00100 00100 00100 00100', 'Z': '11111 00001 00010 00100 01000 10000 11111',
    '0': '01110 10001 10011 10101 11001 10001 01110', '1': '00100 01100 00100 00100 00100 00100 01110',
    '2': '01110 10001 00001 00010 00100 01000 11111', '3': '11110 00001 00001 01110 00001 00001 11110',
    '4': '00010 00110 01010 10010 11111 00010 00010', '5': '11111 10000 10000 11110 00001 00001 11110',
    '6': '01110 10000 10000 11110 10001 10001 01110', '7': '11111 00001 00010 00100 01000 01000 01000',
    '8': '01110 10001 10001 01110 10001 10001 01110', '9': '01110 10001 10001 01111 00001 00001 01110',
    '-': '00000 00000 00000 11111 00000 00000 00000', '+': '00000 00100 00100 11111 00100 00100 00000',
    '=': '00000 00000 11111 00000 11111 00000 00000', '/': '00001 00001 00010 00100 01000 10000 10000',
    '.': '00000 00000 00000 00000 00000 00110 00110', ',': '00000 00000 00000 00000 00110 00010 00100',
    ':': '00000 00100 00000 00000 00000 00100 00000', '(': '00010 00100 01000 01000 01000 00100 00010',
    ')': '01000 00100 00010 00010 00010 00100 01000', "'": '00100 00100 01000 00000 00000 00000 00000',
    '?': '01110 10001 00001 00010 00100 00000 00100', '!': '00100 00100 00100 00100 00100 00000 00100',
    '<': '00001 00010 00100 01000 00100 00010 00001', '>': '10000 01000 00100 00010 00100 01000 10000',
    '*': '00000 10101 01110 11111 01110 10101 00000', '[': '01110 01000 01000 01000 01000 01000 01110',
    ']': '01110 00010 00010 00010 00010 00010 01110', '%': '11000 11001 00010 00100 01000 10011 00011',
    '&': '01100 10010 10100 01000 10101 10010 01101', '"': '01010 01010 01010 00000 00000 00000 00000',
    '#': '01010 01010 11111 01010 11111 01010 01010', '^': '00100 01010 10001 00000 00000 00000 00000',
    '_': '00000 00000 00000 00000 00000 00000 11111', '|': '00100 00100 00100 00100 00100 00100 00100',
    'Γ': '11111 10000 10000 10000 10000 10000 10000', 'Δ': '00100 00100 01010 01010 10001 10001 11111',
    'Θ': '01110 10001 10001 11111 10001 10001 01110', 'Λ': '00100 00100 01010 01010 10001 10001 10001',
    'Ξ': '11111 00000 00000 01110 00000 00000 11111', 'Π': '11111 10001 10001 10001 10001 10001 10001',
    'Σ': '11111 10000 01000 00100 01000 10000 11111', 'Φ': '00100 01110 10101 10101 10101 01110 00100',
    'Ψ': '10101 10101 10101 01110 00100 00100 00100', 'Ω': '01110 10001 10001 10001 01010 01010 11011',
    'ϛ': '01110 10001 10000 01110 00001 00001 01110', '°': '01100 10010 10010 01100 00000 00000 00000',
    'ω': '00000 00000 10001 10101 10101 10101 01010', 'ρ': '00000 00000 01110 10001 10001 11110 10000',
    '☉': '00000 01110 10001 10101 10001 01110 00000', '☾': '00110 01100 11000 11000 11000 01100 00110',
    '→': '00000 00100 00010 11111 00010 00100 00000', '←': '00000 00100 01000 11111 01000 00100 00000',
    '•': '00000 00000 01110 01110 01110 00000 00000',
}


def write_font():
    lines = ['// SPDX-License-Identifier: GPL-2.0-or-later',
             '// Generated by tools/generate_tables.py. 5x7 glyphs in a 6x8 cell.',
             'module am_font (', '\tinput  wire [7:0] character,', '\tinput  wire [2:0] x,',
             '\tinput  wire [2:0] y,', '\toutput wire       pixel', ');',
             'reg [34:0] glyph;', 'always @* begin', '\tcase(character)']
    for ch, rows in FONT.items():
        bits = ''.join(rows.split())
        assert len(bits) == 35
        code = encode(ch)[0]
        lines.append(f"\t\t8'h{code:02x}: glyph = 35'b{bits}; // {ch}")
    lines += ['\t\tdefault: glyph = 0;', '\tendcase', 'end',
              "assign pixel = x < 5 && y < 7 && glyph[(6-int'(y))*5 + 4-int'(x)];", 'endmodule', '']
    (ROOT / 'rtl/am_font.sv').write_text('\n'.join(lines))


# ---------------------------------------------------------------------------
# Text ROM.
# ---------------------------------------------------------------------------
class TextRom:
    def __init__(self):
        self.data: list[int] = []
        self.names: dict[str, tuple[int, int]] = {}      # name -> (offset, length)
        self.tables: dict[str, tuple[int, int, int]] = {}  # name -> (base, stride, count)

    def add(self, name: str, text: str) -> int:
        codes = encode(text)
        self.names[name] = (len(self.data), len(codes))
        self.data += codes
        return len(self.data) - len(codes)

    def add_table(self, name: str, items: list[str], stride: int | None = None):
        stride = stride or max(len(encode(s)) for s in items)
        base = len(self.data)
        for s in items:
            codes = encode(s)
            assert len(codes) <= stride, (name, s)
            self.data += codes + [32] * (stride - len(codes))
        self.tables[name] = (base, stride, len(items))


def ring_string(length: int, labels: list[tuple[float, str]]) -> str:
    """Place labels centred at fractions of a turn into a string of `length` chars."""
    cells = [' '] * length
    for frac, text in labels:
        start = round(frac * length - len(text) / 2) % length
        for i, ch in enumerate(text):
            cells[(start + i) % length] = ch
    return ''.join(cells)


# Geometry shared with the RTL and the screenshot checker.
GEOM = {
    'FRONT_CX': 220, 'FRONT_CY': 240,
    'R_EGY_OUT': 208, 'R_EGY_TEXT': 201, 'R_EGY_IN': 192,
    'R_ZOD_OUT': 190, 'R_ZOD_TEXT': 183, 'R_ZOD_IN': 170,
    'R_PARA_TEXT': 167, 'R_PARA_IN': 158,
    'R_SATURN': 150, 'R_JUPITER': 136, 'R_MARS': 122, 'R_SUN': 108, 'R_VENUS': 94,
    'R_MERCURY': 80, 'R_MOON': 60, 'R_DOME': 44, 'R_DRAGON': 150, 'R_DATE': 206,
    'MET_CX': 122, 'MET_CY': 117, 'MET_R0': 48, 'MET_R1': 100,
    'GAMES_CX': 147, 'GAMES_CY': 110, 'CAL_CX': 97, 'CAL_CY': 110, 'SUB_R': 20,
    'SAR_CX': 122, 'SAR_CY': 331, 'SAR_R0': 48, 'SAR_R1': 100,
    'EXEL_CX': 148, 'EXEL_CY': 328, 'BACK_SPLIT': 224,
    'SPIRAL_SPAN': 52, 'MET_PITCH_INV': round(65536 / (52 / 5)), 'SAR_PITCH_INV': round(65536 / (52 / 4)),
    'ZOD_RING_CHARS': 192, 'EGY_RING_CHARS': 210, 'PARA_RING_CHARS': 180, 'SUB_RING_CHARS': 16,
}


def build_text_rom() -> TextRom:
    rom = TextRom()
    rom.add_table('ZODIAC_GR', [g for g, e in M.ZODIAC])
    rom.add_table('ZODIAC_EN', [e for g, e in M.ZODIAC])
    rom.add_table('EGYPT_GR', [g for g, e in M.EGYPTIAN])
    rom.add_table('EGYPT_EN', [e for g, e in M.EGYPTIAN])
    rom.add_table('CORINTH_GR', [g for g, e in M.CORINTHIAN])
    rom.add_table('CORINTH_EN', [e for g, e in M.CORINTHIAN])
    rom.add_table('GAMES_GR', [g for g, e in M.GAMES_DIAL])
    rom.add_table('GAMES_EN', [e for g, e in M.GAMES_DIAL])
    rom.add_table('PLANET_GR', [g for g, e in M.PLANETS])
    rom.add_table('PLANET_EN', [e for g, e in M.PLANETS])
    rom.add_table('PHASE', M.PHASES)
    rom.add_table('JMONTH', M.JULIAN_MONTHS)
    rom.add_table('PARAPEGMA', [t for lon, letter, t in sorted(M.PARAPEGMA)])
    rom.add_table('PARA_LETTER', [letter or ' ' for lon, letter, t in sorted(M.PARAPEGMA)], 1)
    rom.add_table('EXEL', ['+0 HOURS', '+8 HOURS', '+16 HOURS'])
    rom.add_table('SPEED', ['1 DAY/S', '1 WEEK/S', '1 MONTH/S', '1 YEAR/S', '4 YEARS/S',
                            '19 YEARS/S', '76 YEARS/S', '1 CENTURY/S'])
    rom.add_table('VIEW', ['FRONT DIAL', 'BACK DIALS', 'GEAR TRAIN'])
    rom.add_table('EPOCH', ['EPOCH 205 BC', 'EPOCH 178 BC'])
    rom.add_table('RING_KIND', ['EGYPTIAN 365', 'LUNAR 354'])
    rom.add_table('ERA', ['AD', 'BC'])
    # Ring inscriptions, one character per 1/N turn, clockwise from the top.
    zod = ring_string(GEOM['ZOD_RING_CHARS'], [((i + 0.5) / 12, g) for i, (g, e) in enumerate(M.ZODIAC)])
    rom.add('ZOD_RING', zod)
    egy_labels = [((30 * i + 15) / 365, g) for i, (g, e) in enumerate(M.EGYPTIAN[:12])]
    egy_labels.append(((360 + 2.5) / 365, 'ΕΠΑΓ'))
    rom.add('EGY_RING', ring_string(GEOM['EGY_RING_CHARS'], egy_labels))
    lunar_labels = []
    start = 0
    for i, (g, e) in enumerate(M.EGYPTIAN[:12]):
        length = 30 if i % 2 == 0 else 29
        lunar_labels.append(((start + length / 2) / 354, g))
        start += length
    rom.add('LUNAR_RING', ring_string(GEOM['EGY_RING_CHARS'], lunar_labels))
    para = [(lon / 360, letter) for lon, letter, t in M.PARAPEGMA if letter]
    rom.add('PARA_RING', ring_string(GEOM['PARA_RING_CHARS'], para))
    # Games dial runs anticlockwise; year 1 starts at the bottom (6 o'clock).
    games = [((0.5 - (i + 0.5) / 4) % 1, 'L' + 'ABΓΔ'[i]) for i in range(4)]
    rom.add('GAMES_RING', ring_string(GEOM['SUB_RING_CHARS'], games))
    cal = [((0.5 + (i + 0.5) / 4) % 1, 'ABΓΔ'[i]) for i in range(4)]
    rom.add('CAL_RING', ring_string(GEOM['SUB_RING_CHARS'], cal))
    # Exeligmos sectors begin at 1, 5 and 9 o'clock.
    exel = [((30 + 120 * i + 60) / 360, t) for i, t in enumerate(['O', 'H', 'Iϛ'])]
    rom.add('EXEL_RING', ring_string(GEOM['SUB_RING_CHARS'], exel))
    # Static labels.
    labels = {
        'TITLE': 'ANTIKYTHERA MECHANISM', 'L_DATE': 'DATE', 'L_EGYPT': 'EGYPTIAN', 'L_LUNAR_RING': 'LUNAR', 'L_SUN': 'SUN',
        'L_MEAN': 'DATE PTR', 'L_MOON': 'MOON', 'L_PHASE': 'PHASE', 'L_NODE': 'NODE',
        'L_APOGEE': 'APOGEE', 'L_PLANETS': 'PLANETS (2021 COSMOS)', 'L_PARAPEGMA': 'PARAPEGMA',
        'L_CRANK': 'CRANK', 'L_TURNS': 'TURNS', 'L_RUN': 'RUNNING', 'L_PAUSED': 'PAUSED',
        'L_BACK': 'BACKWARDS', 'L_ECLIPSE': 'ECLIPSE SEASON', 'L_RETRO': 'R',
        'L_METONIC': 'METONIC DIAL', 'L_CELL': 'CELL', 'L_OF235': '/235', 'L_OF223': '/223',
        'L_YEAR': 'YEAR', 'L_MONTH': 'MONTH', 'L_INTERCAL': '(INTERCALARY)',
        'L_GAMES': 'GAMES DIAL', 'L_CALLIPPIC': 'CALLIPPIC', 'L_PERIOD': 'PERIOD', 'L_OF4': '/4',
        'L_SAROS': 'SAROS DIAL', 'L_EXEL': 'EXELIGMOS', 'L_THISMONTH': 'THIS MONTH',
        'L_NEXT': 'NEXT ECLIPSE', 'L_LUNAR': 'Σ LUNAR', 'L_SOLAR': 'H SOLAR', 'L_HOUR': 'ωρ',
        'L_DAY': 'HM', 'L_NIGHT': 'NY', 'L_NONE': 'NO ECLIPSE', 'L_INMONTHS': 'MONTHS',
        'L_INSCRIBED': 'INSCRIBED', 'L_IN': 'IN', 'L_MODEL': 'RECONSTRUCTED', 'L_GEARS': 'GEAR TRAIN',
        'L_TEETH': 'TEETH', 'L_DEG': '°', 'L_KEYS': 'SPACE RUN   </> DAY   F1 HELP   F12 MENU',
        'L_RINGADJ': 'RING', 'L_AUTO': 'AUTO', 'L_MANUAL': 'MANUAL', 'L_AGE': 'AGE',
        'L_DAYS': 'DAYS', 'L_B1': 'B1', 'L_CYCLE': 'CYCLE', 'L_EP205': 'FREETH / JONES 205 BC',
        'L_EP178': 'VOULGARIS 178 BC', 'L_LAT': 'LAT',
        'H_TITLE': 'CONTROLS', 'H_1': 'SPACE      RUN / PAUSE', 'H_2': 'LEFT/RIGHT ONE DAY BACK / FORWARD',
        'H_3': 'DOWN/UP    ONE LUNAR MONTH', 'H_4': 'PGDN/PGUP  ONE YEAR',
        'H_5': '- / +      SLOWER / FASTER', 'H_6': 'R          REVERSE DIRECTION',
        'H_7': 'TAB 1 2 3  FRONT / BACK / GEARS', 'H_8': 'HOME       RETURN TO THE EPOCH',
        'H_9': '[ ]        TURN THE CALENDAR RING', 'H_10': 'F12        EPOCH, RING, SPEED, GAMEPAD',
        'H_11': 'THE CRANK TURNS GEAR B1 ONCE A YEAR.', 'H_12': 'ALL POINTERS FOLLOW FROM THE GEAR TEETH.',
        'H_13': 'F1 OR ESC TO CLOSE',
        'G_FRONT': 'FRONT', 'G_BACK': 'BACK', 'G_CRANK': 'CRANK A1', 'G_MOON': 'MOON',
        'G_SUN': 'SUN', 'G_METONIC': 'METONIC', 'G_SAROS': 'SAROS', 'G_PINSLOT': 'PIN AND SLOT',
    }
    for name, text in labels.items():
        rom.add(name, text)
    return rom


# ---------------------------------------------------------------------------
# Gear-train view layout. Positions are schematic: meshing gears touch,
# coaxial gears share a centre. The e1-b3 return to the front dial is drawn as
# a link because e sits behind b1 in the real Mechanism.
# ---------------------------------------------------------------------------
def gear_radius(teeth: int) -> float:
    return 5 + teeth * 0.38


def gear_layout() -> list[dict]:
    g = M.GEARS
    r = {name: gear_radius(t) for name, t in g.items()}
    axes: dict[str, tuple[float, float]] = {}

    def place(axis: str, from_axis: str, dist: float, angle_deg: float):
        fx, fy = axes[from_axis]
        a = math.radians(angle_deg)
        axes[axis] = (fx + dist * math.cos(a), fy + dist * math.sin(a))

    axes['B'] = (150, 262)
    place('A', 'B', r['b1'] + r['a1'], 180)
    place('L', 'B', r['b2'] + r['l1'], -112)
    place('M', 'L', r['l2'] + r['m1'], -60)
    place('N', 'M', r['m2'] + r['n1'], -8)
    place('O', 'N', r['n2'] + r['o1'], 20)
    place('P', 'N', r['n3'] + r['p1'], -50)
    place('Q', 'P', r['p2'] + r['q1'], 10)
    place('E', 'M', r['m3'] + r['e3'], 42)
    place('D', 'E', r['d2'] + r['e2'], 150)
    place('C', 'D', r['c2'] + r['d1'], 215)
    place('K', 'E', r['e5'] + r['k1'], -100)
    place('F', 'E', r['e4'] + r['f1'], 75)
    place('G', 'F', r['f2'] + r['g1'], 15)
    place('H', 'G', r['g2'] + r['h1'], 25)
    place('I', 'H', r['h2'] + r['i1'], -40)
    # (axis, gear, shaft name, direction, label)
    table = [
        ('A', 'a1', 'crank', 1), ('B', 'b1', 'sun_mean', 1), ('B', 'b2', 'sun_mean', 1),
        ('B', 'b3', 'moon_true', 1), ('L', 'l1', 'c', -1), ('L', 'l2', 'c', -1),
        ('M', 'm1', 'm', 1), ('M', 'm2', 'm', 1), ('M', 'm3', 'm', 1),
        ('N', 'n1', 'n', -1), ('N', 'n2', 'n', -1), ('N', 'n3', 'n', -1),
        ('O', 'o1', 'games', 1), ('P', 'p1', 'p', 1), ('P', 'p2', 'p', 1), ('Q', 'q1', 'callippic', -1),
        ('E', 'e3', 'apsides', -1), ('E', 'e4', 'apsides', -1), ('E', 'e2', 'moon_mean', 1),
        ('E', 'e5', 'moon_mean', 1), ('E', 'e6', 'moon_true', -1), ('E', 'e1', 'moon_true', -1),
        ('C', 'c1', 'c', -1), ('C', 'c2', 'c', -1), ('D', 'd1', 'd', 1), ('D', 'd2', 'd', 1),
        ('K', 'k1', 'k1', -1), ('K', 'k2', 'k2', 1),
        ('F', 'f1', 'f', 1), ('F', 'f2', 'f', 1), ('G', 'g1', 'g', -1), ('G', 'g2', 'g', -1),
        ('H', 'h1', 'h', 1), ('H', 'h2', 'h', 1), ('I', 'i1', 'exeligmos', -1),
    ]
    out = []
    for axis, gear, shaft, direction in table:
        x, y = axes[axis]
        out.append({'name': gear, 'x': round(x), 'y': round(y), 'r': round(r[gear]),
                    'teeth': g[gear], 'shaft': shaft, 'dir': direction})
    return out


# Shafts the hardware accumulates: the 16 of the model plus gear-view rates.
HW_SHAFTS = [(s.name, s.rate) for s in M.SHAFTS] + [
    ('c', M.ratio(('b2', 'c1'))),
    ('d', M.ratio(('b2', 'c1'), ('c2', 'd1'))),
    ('m', M.ratio(('b2', 'l1'), ('l2', 'm1'))),
    ('p', M.METONIC_TURNS * M.ratio(('n3', 'p1'))),
    ('f', M.APSIDES * M.ratio(('e4', 'f1'))),
    ('h', M.SAROS_TURNS * M.ratio(('g2', 'h1'))),
    ('crank', M.Fraction(M.GEARS['b1'], M.GEARS['a1'])),
]
# Display-only angles derived from the shafts (gear view).
DERIVED = {'moon_true': 'moon longitude with the anomaly', 'n': '5 x metonic', 'g': '4 x saros',
           'k1': 'apsides + moon anomaly', 'k2': 'k1 + pin-and-slot output'}


def shaft_index(name: str) -> int:
    names = [n for n, r in HW_SHAFTS]
    if name in names:
        return names.index(name)
    return len(HW_SHAFTS) + list(DERIVED).index(name)


def write_tables(rom: TextRom):
    year_ticks = int(M.YEAR_TICKS)
    L = ['// SPDX-License-Identifier: GPL-2.0-or-later',
         '// Generated by tools/generate_tables.py from tools/mechanism.py. Do not edit.',
         f'localparam integer NSHAFT = {len(HW_SHAFTS)};',
         f'localparam integer NDERIVED = {len(DERIVED)};',
         f'localparam [27:0] YEAR_TICKS = 28\'d{year_ticks};',
         f'localparam integer NEPOCH = {len(M.EPOCHS)};',
         f'localparam integer NGEAR = {len(gear_layout())};',
         f'localparam integer NPARAPEGMA = {len(M.PARAPEGMA)};',
         f'localparam integer NGLYPHCELLS = 223;', '']
    for k, v in GEOM.items():
        L.append(f'localparam integer {k} = {v};')
    for i, (name, rate) in enumerate(HW_SHAFTS):
        L.append(f'localparam integer SH_{name.upper()} = {i};')
    for i, name in enumerate(DERIVED):
        L.append(f'localparam integer SH_{name.upper()} = {len(HW_SHAFTS) + i};')
    L.append('')
    # Shaft rate numerators (|num|), moduli and direction.
    L.append('function automatic [16:0] shaft_num(input integer i, input is224);')
    L.append('\tcase(i)')
    for i, (name, rate) in enumerate(HW_SHAFTS):
        if name == 'crank':
            L.append(f"\t\t{i}: shaft_num = is224 ? 17'd224 : 17'd223;")
        else:
            assert abs(rate.numerator) < (1 << 17)
            L.append(f"\t\t{i}: shaft_num = 17'd{abs(rate.numerator)}; // {name} {rate}")
    L += ['\t\tdefault: shaft_num = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [39:0] shaft_mod(input integer i);')
    L.append('\tcase(i)')
    for i, (name, rate) in enumerate(HW_SHAFTS):
        mod = rate.denominator * year_ticks
        assert mod < (1 << 40)
        L.append(f"\t\t{i}: shaft_mod = 40'd{mod};")
    L += ['\t\tdefault: shaft_mod = 1;', '\tendcase', 'endfunction', '']
    L.append('function automatic shaft_neg(input integer i);')
    L.append('\tcase(i)')
    for i, (name, rate) in enumerate(HW_SHAFTS):
        L.append(f"\t\t{i}: shaft_neg = 1'b{1 if rate < 0 else 0};")
    L += ['\t\tdefault: shaft_neg = 0;', '\tendcase', 'endfunction', '']
    # Epoch data.
    L.append('function automatic [39:0] epoch_f0(input integer ep, input integer i);')
    L.append('\tcase(ep * 64 + i)')
    for epoch in M.EPOCHS:
        phases = M.epoch_phases(epoch)
        for i, (name, rate) in enumerate(HW_SHAFTS):
            mod = rate.denominator * year_ticks
            phase = phases.get(name, M.Fraction(0))
            f0 = int(round(phase * mod)) % mod
            L.append(f"\t\t{epoch.index * 64 + i}: epoch_f0 = 40'd{f0};")
    L += ['\t\tdefault: epoch_f0 = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [23:0] epoch_jdn(input integer ep);')
    L.append('\tcase(ep)')
    for epoch in M.EPOCHS:
        jdn, off = M.epoch_day_fields(epoch)
        L.append(f"\t\t{epoch.index}: epoch_jdn = 24'd{jdn};")
    L += ['\t\tdefault: epoch_jdn = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [15:0] epoch_tick_offset(input integer ep);')
    L.append('\tcase(ep)')
    for epoch in M.EPOCHS:
        jdn, off = M.epoch_day_fields(epoch)
        L.append(f"\t\t{epoch.index}: epoch_tick_offset = 16'd{off};")
    L += ['\t\tdefault: epoch_tick_offset = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [8:0] epoch_egyptian_adjust(input integer ep);')
    L.append('\tcase(ep)')
    for epoch in M.EPOCHS:
        jdn, off = M.epoch_day_fields(epoch)
        adj = 0
        if epoch.egyptian_override:
            m, d = M.egyptian_date(jdn)
            want = epoch.egyptian_override[0] * 30 + epoch.egyptian_override[1] - 1
            adj = (want - (m * 30 + d - 1)) % 365
        L.append(f"\t\t{epoch.index}: epoch_egyptian_adjust = 9'd{adj};")
    L += ['\t\tdefault: epoch_egyptian_adjust = 0;', '\tendcase', 'endfunction', '']
    L.append(f"localparam [23:0] NABONASSAR_JDN = 24'd{M.NABONASSAR_JD};")
    # Eccentricities / epicycle ratios in Q14 for the CORDIC datapath.
    L.append('function automatic [15:0] body_eccentricity(input integer body);')
    L.append('\tcase(body)')
    for i, body in enumerate(['sun', 'moon', 'mercury', 'venus', 'mars', 'jupiter', 'saturn']):
        q = round(float(M.EPICYCLE[body]) * (1 << 14))
        L.append(f"\t\t{i}: body_eccentricity = 16'd{q}; // {body} {float(M.EPICYCLE[body]):.4f}")
    L += ['\t\tdefault: body_eccentricity = 0;', '\tendcase', 'endfunction', '']
    # Saros glyphs: {lunar, solar, lunar_day, lunar_hour[3:0], solar_day, solar_hour[3:0], preserved}.
    L.append('function automatic [12:0] saros_glyph(input [7:0] c); // cell 0..222')
    L.append('\tcase(c)')
    for row in M.glyph_table():
        m = row['month']
        lun, sol = row['lunar'], row['solar']
        ld, lh = row.get('lunar_time', (False, 0))
        sd, sh = row.get('solar_time', (False, 0))
        preserved = (m in M.PRESERVED_LUNAR_TIMES) or (m in M.PRESERVED_SOLAR_TIMES)
        if lun or sol:
            val = (preserved << 12) | (int(lun) << 11) | (int(ld) << 10) | ((lh & 15) << 6) | (int(sol) << 5) | (int(sd) << 4) | (sh & 15)
            L.append(f"\t\t{m - 1}: saros_glyph = 13'h{val:04x}; // month {m}{' Σ' if lun else ''}{' Η' if sol else ''}")
    L += ['\t\tdefault: saros_glyph = 0;', '\tendcase', 'endfunction', '']
    # Metonic cells: {year[4:0], month[3:0], repeated}.
    L.append('function automatic [9:0] metonic_info(input [7:0] c); // cell 0..234')
    L.append('\tcase(c)')
    for i, (year, month, rep) in enumerate(M.metonic_cells()):
        L.append(f"\t\t{i}: metonic_info = {{5'd{year}, 4'd{month}, 1'b{int(rep)}}};")
    L += ["\t\tdefault: metonic_info = 0;", '\tendcase', 'endfunction', '']
    # Parapegma longitudes in 1/4096 turn.
    L.append('function automatic [11:0] parapegma_pos(input integer i);')
    L.append('\tcase(i)')
    for i, (lon, letter, text) in enumerate(sorted(M.PARAPEGMA)):
        L.append(f"\t\t{i}: parapegma_pos = 12'd{round(lon / 360 * 4096) % 4096}; // {letter} {text}")
    L += ['\t\tdefault: parapegma_pos = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [15:0] angle_per_pixel(input [8:0] r); // 1 px at radius r, in 1/65536 turn')
    L.append('\tcase(r)')
    for r in range(512):
        v = min(65535, round(65536 / (2 * math.pi * max(r, 1))))
        L.append(f"\t\t{r}: angle_per_pixel = 16'd{v};")
    L += ['\t\tdefault: angle_per_pixel = 0;', '\tendcase', 'endfunction', '']
    # Gear view.
    axes = []
    for gear in gear_layout():
        if (gear['x'], gear['y']) not in axes:
            axes.append((gear['x'], gear['y']))
    L.append(f'localparam integer NAXIS = {len(axes)};')
    L.append('// {x[9:0], y[8:0], r[6:0], teeth[7:0], shaft[4:0], dir}')
    L.append('function automatic [39:0] gear_info(input integer i);')
    L.append('\tcase(i)')
    for i, gear in enumerate(gear_layout()):
        L.append(f"\t\t{i}: gear_info = {{10'd{gear['x']}, 9'd{gear['y']}, 7'd{gear['r']}, 8'd{gear['teeth']}, "
                 f"5'd{shaft_index(gear['shaft'])}, 1'b{1 if gear['dir'] > 0 else 0}}}; // {gear['name']}")
    L += ['\t\tdefault: gear_info = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [3:0] gear_axis(input integer i);')
    L.append('\tcase(i)')
    for i, gear in enumerate(gear_layout()):
        L.append(f"\t\t{i}: gear_axis = 4'd{axes.index((gear['x'], gear['y']))};")
    L += ['\t\tdefault: gear_axis = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [18:0] axis_pos(input integer i); // {x[9:0], y[8:0]}')
    L.append('\tcase(i)')
    for i, (x, y) in enumerate(axes):
        L.append(f"\t\t{i}: axis_pos = {{10'd{x}, 9'd{y}}};")
    L += ['\t\tdefault: axis_pos = 0;', '\tendcase', 'endfunction', '']
    L.append('function automatic [15:0] gear_label(input integer i); // two characters')
    L.append('\tcase(i)')
    for i, gear in enumerate(gear_layout()):
        a, b = encode(gear['name'].upper())
        L.append(f"\t\t{i}: gear_label = {{8'h{a:02x}, 8'h{b:02x}}};")
    L += ["\t\tdefault: gear_label = 16'h2020;", '\tendcase', 'endfunction', '']
    # Text ROM directory.
    L.append(f'localparam integer TEXT_ROM_SIZE = {len(rom.data)};')
    for name, (off, length) in rom.names.items():
        L.append(f'localparam integer STR_{name} = {off};')
        L.append(f'localparam integer LEN_{name} = {length};')
    for name, (base, stride, count) in rom.tables.items():
        L.append(f'localparam integer TAB_{name} = {base};')
        L.append(f'localparam integer TAB_{name}_STRIDE = {stride};')
        L.append(f'localparam integer TAB_{name}_COUNT = {count};')
    (ROOT / 'rtl/am_tables.svh').write_text('\n'.join(L) + '\n')


def write_strings(rom: TextRom):
    size = 1 << (len(rom.data) - 1).bit_length()
    L = ['// SPDX-License-Identifier: GPL-2.0-or-later',
         '// Generated by tools/generate_tables.py. Synchronous text ROM.',
         'module am_strings (', '\tinput  wire        clk,', '\tinput  wire        ce,', f'\tinput  wire [{(size - 1).bit_length() - 1}:0] address,',
         '\toutput reg  [7:0]  data', ');',
         f'reg [7:0] rom [0:{size - 1}];', 'integer i;', 'initial begin',
         f'\tfor(i = 0; i < {size}; i = i + 1) rom[i] = 8\'h20;']
    for i, code in enumerate(rom.data):
        L.append(f"\trom[{i}] = 8'h{code:02x};")
    L += ['end', 'always @(posedge clk) if(ce) data <= rom[address];', 'endmodule', '']
    (ROOT / 'rtl/am_strings.sv').write_text('\n'.join(L))


def main():
    M.check_metonic_against_jones()
    M.check_glyphs()
    rom = build_text_rom()
    write_font()
    write_strings(rom)
    write_tables(rom)
    print(f'text rom: {len(rom.data)} bytes, {len(rom.names)} strings, {len(rom.tables)} tables')
    for gear in gear_layout():
        print(f"  {gear['name']:3s} at ({gear['x']:3d},{gear['y']:3d}) r={gear['r']:2d} teeth={gear['teeth']}")


if __name__ == '__main__':
    main()
