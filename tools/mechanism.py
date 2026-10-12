#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Reference model of the Antikythera Mechanism as implemented by the core.

Everything the RTL does is defined here first: the gear train and its exact
ratios, the two candidate epochs, the calendars on the dials, the eclipse
scheme of the Saros dial and the parapegma. The RTL tables are generated from
this file (see generate_tables.py) and the simulation compares the RTL against
the functions here.

Sources (see docs/research.md): Freeth et al. 2006 (gear counts, trains),
Freeth et al. 2008 (Metonic calendar, Games dial), Freeth 2014 (Eclipse Year
Model, 205 BC Saros epoch), Iversen 2017 / Jones 2017 (Corinthian calendar,
intercalation, 205 BC calendar epoch), Freeth et al. 2021 (Cosmos display,
planetary period relations), Voulgaris et al. 2022 (178 BC epoch) and
Woan & Bayley 2024 (calendar ring hole count).
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from fractions import Fraction

# ---------------------------------------------------------------------------
# Gear train. Tooth counts from Freeth et al. 2006 Supplementary Notes 3,
# with the 2008 reassignment of axis n/o/p/q (Games and Callippic dials).
# ---------------------------------------------------------------------------
GEARS = {
    'a1': 48, 'b1': 223, 'b2': 64, 'b3': 32,
    'c1': 38, 'c2': 48, 'd1': 24, 'd2': 127,
    'e1': 32, 'e2': 32, 'e3': 223, 'e4': 188, 'e5': 50, 'e6': 50,
    'f1': 53, 'f2': 30, 'g1': 54, 'g2': 20, 'h1': 60, 'h2': 15, 'i1': 60,
    'k1': 50, 'k2': 50, 'l1': 38, 'l2': 53,
    'm1': 96, 'm2': 15, 'm3': 27, 'n1': 53, 'n2': 57, 'n3': 15,
    'o1': 60, 'p1': 60, 'p2': 12, 'q1': 60, 'r1': 63,
}
# b1 is read as 223 or 224 teeth; it only changes the crank-to-year ratio.
B1_ALTERNATIVES = (223, 224)

# Period relations of the 2021 Cosmos reconstruction (synodic cycles, years).
PLANET_PERIODS = {
    'mercury': (1513, 480),
    'venus': (289, 462),
    'mars': (133, 284),
    'jupiter': (315, 344),
    'saturn': (427, 442),
}
# Epicycle radius / deferent radius used by the pin-and-slot devices
# (Almagest values, in sixtieths), and the Hipparchan eccentricities.
EPICYCLE = {
    'mercury': Fraction(45, 120),   # 22;30
    'venus': Fraction(259, 360),    # 43;10
    'mars': Fraction(79, 120),      # 39;30
    'jupiter': Fraction(23, 120),   # 11;30
    'saturn': Fraction(13, 120),    # 6;30
    'moon': Fraction(21, 240),      # 5;15 (pin offset / pin radius of k1-k2)
    'sun': Fraction(1, 24),         # 2;30
}
SUN_APOGEE_DEG = 65.5               # Hipparchus: Gemini 5 1/2 degrees
NODE_RATE = Fraction(-5, 93)        # Dragon Hand: 5 retrograde turns in 93 years

DAY_TICKS = 1 << 16                 # core time unit: 1/65536 day
YEAR_DAYS = Fraction(1461, 4)       # one turn of b1 = a Callippic year
YEAR_TICKS = YEAR_DAYS * DAY_TICKS  # 23937024, an integer


def ratio(*pairs: tuple[str, str]) -> Fraction:
    """Product of driver/driven tooth ratios along a train."""
    r = Fraction(1)
    for driver, driven in pairs:
        r *= Fraction(GEARS[driver], GEARS[driven])
    return r


# Turns per year of every shaft the display needs (all from the gear counts).
SIDEREAL_MOON = ratio(('b2', 'c1'), ('c2', 'd1'), ('d2', 'e2'))             # 254/19
APSIDES = ratio(('b2', 'l1'), ('l2', 'm1'), ('m3', 'e3'))                   # 477/4237
ANOMALISTIC = SIDEREAL_MOON - APSIDES                                        # 56165/4237
METONIC_TURNS = ratio(('b2', 'l1'), ('l2', 'm1'), ('m2', 'n1'))             # 5/19
METONIC_CYCLE = METONIC_TURNS / 5                                           # 1/19
GAMES = METONIC_TURNS * ratio(('n2', 'o1'))                                 # 1/4
CALLIPPIC = METONIC_TURNS * ratio(('n3', 'p1'), ('p2', 'q1'))               # 1/76
SAROS_TURNS = APSIDES * ratio(('e4', 'f1'), ('f2', 'g1'))                   # 940/4237
SAROS_CYCLE = SAROS_TURNS / 4                                               # 235/4237
EXELIGMOS = SAROS_TURNS * ratio(('g2', 'h1'), ('h2', 'i1'))                 # 235/50844
SYNODIC = SIDEREAL_MOON - 1                                                 # 235/19
assert SIDEREAL_MOON == Fraction(254, 19) and METONIC_TURNS == Fraction(5, 19)
assert GAMES == Fraction(1, 4) and CALLIPPIC == Fraction(1, 76)
assert SAROS_CYCLE == Fraction(235, 19 * 223) and EXELIGMOS == SAROS_CYCLE / 3
assert ANOMALISTIC == Fraction(56165, 4237)


def planet_rates(name: str) -> tuple[Fraction, Fraction]:
    """(synodic, sidereal) turns per year from the period relation."""
    syn, years = PLANET_PERIODS[name]
    if name in ('mercury', 'venus'):
        return Fraction(syn, years), Fraction(1)
    return Fraction(syn, years), Fraction(years - syn, years)


# ---------------------------------------------------------------------------
# Shafts tracked by the core. Each has an exact rate in turns per b1 turn and
# an epoch phase (in turns) that depends on the chosen epoch.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Shaft:
    index: int
    name: str
    rate: Fraction          # turns per year (per revolution of b1)
    description: str


SHAFTS = [
    Shaft(0, 'sun_mean', Fraction(1), 'mean Sun / date pointer longitude'),
    Shaft(1, 'sun_anomaly', Fraction(1), 'mean Sun measured from apogee'),
    Shaft(2, 'moon_mean', SIDEREAL_MOON, 'mean Moon longitude (e2 / e5)'),
    Shaft(3, 'moon_anomaly', ANOMALISTIC, 'k1 relative to e3, from apogee'),
    Shaft(4, 'nodes', NODE_RATE, 'ascending node longitude (Dragon Hand)'),
    Shaft(5, 'metonic', METONIC_CYCLE, 'fraction of the 19-year cycle'),
    Shaft(6, 'saros', SAROS_CYCLE, 'fraction of the 223-month cycle'),
    Shaft(7, 'exeligmos', EXELIGMOS, 'fraction of three Saros cycles'),
    Shaft(8, 'games', GAMES, 'fraction of the 4-year Games cycle'),
    Shaft(9, 'callippic', CALLIPPIC, 'fraction of the 76-year cycle'),
    Shaft(10, 'mercury', planet_rates('mercury')[0], 'Mercury epicycle anomaly'),
    Shaft(11, 'venus', planet_rates('venus')[0], 'Venus epicycle anomaly'),
    Shaft(12, 'mars', planet_rates('mars')[1], 'Mars mean longitude'),
    Shaft(13, 'jupiter', planet_rates('jupiter')[1], 'Jupiter mean longitude'),
    Shaft(14, 'saturn', planet_rates('saturn')[1], 'Saturn mean longitude'),
    Shaft(15, 'apsides', APSIDES, 'e3: lunar apogee longitude carrier'),
]
SHAFT_BY_NAME = {s.name: s for s in SHAFTS}


def shaft_modulus(shaft: Shaft) -> int:
    """F accumulates shaft.rate.numerator per tick modulo this value."""
    return shaft.rate.denominator * int(YEAR_TICKS)


# ---------------------------------------------------------------------------
# Astronomy: Julian days, mean elements (Meeus), used only for the epochs.
# ---------------------------------------------------------------------------
def julian_day(year: int, month: int, day: float) -> float:
    """Julian Day of a proleptic Julian calendar date (year 0 = 1 BC)."""
    if month <= 2:
        year -= 1
        month += 12
    return math.floor(365.25 * (year + 4716)) + math.floor(30.6001 * (month + 1)) + day - 1524.5


def julian_calendar(jdn: int) -> tuple[int, int, int]:
    """Proleptic Julian calendar (year, month, day) of a Julian Day Number."""
    f = jdn + 1402
    e = 4 * f + 3
    g = (e % 1461) // 4
    h = 5 * g + 2
    day = (h % 153) // 5 + 1
    month = ((h // 153 + 2) % 12) + 1
    year = e // 1461 - 4716 + (12 + 2 - month) // 12
    return year, month, day


NABONASSAR_JD = 1448638             # Thoth 1, 747 BC (Egyptian civil calendar)


def egyptian_date(jdn: int) -> tuple[int, int]:
    """(month 0-11 or 12 for the epagomenal days, day 1-30/1-5)."""
    q = (jdn - NABONASSAR_JD) % 365
    return q // 30, q % 30 + 1


def centuries(jd: float) -> float:
    return (jd - 2451545.0) / 36525.0


def mean_new_moon(jd_near: float) -> float:
    """Meeus 49: mean New Moon (JDE) closest to a Julian Day."""
    k = round((jd_near - 2451550.09766) / 29.530588861)
    t = k / 1236.85
    return (2451550.09766 + 29.530588861 * k + 0.00015437 * t * t
            - 0.000000150 * t ** 3 + 0.00000000073 * t ** 4)


def mean_elements(jd: float) -> dict[str, float]:
    """Mean longitudes (degrees, equinox of date) from Meeus."""
    t = centuries(jd)
    poly = lambda *c: sum(ci * t ** i for i, ci in enumerate(c)) % 360
    return {
        'sun': poly(280.46646, 36000.76983, 0.0003032),
        'moon': poly(218.3164477, 481267.88123421, -0.0015786, 1 / 538841, -1 / 65194000),
        'moon_anomaly': poly(134.9633964, 477198.8675055, 0.0087414, 1 / 69699, -1 / 14712000),
        'node': poly(125.0445479, -1934.1362891, 0.0020754, 1 / 467441, -1 / 60616000),
        'mercury': poly(252.250906, 149474.0722491, 0.00030350, 0.000000018),
        'venus': poly(181.979801, 58519.2130302, 0.00031014, 0.000000015),
        'mars': poly(355.433000, 19141.6964471, 0.00031052, 0.000000016),
        'jupiter': poly(34.351519, 3036.3027748, 0.00022330, 0.000000037),
        'saturn': poly(50.077444, 1223.5110686, 0.00051908, -0.000000030),
    }


DELTA_T_DAYS = 12800 / 86400        # ~3.6 h: Terrestrial Time - UT around 200 BC
LOCAL_OFFSET_DAYS = 21.0 / 360      # Epirus / Corinthian colonies, ~21 degrees east
LATITUDE_DEG = 39.0
OBLIQUITY_DEG = 23.7

# ---------------------------------------------------------------------------
# Epochs.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Epoch:
    index: int
    name: str
    jd_utc: float                   # instant of the epoch New Moon (UT)
    metonic_cell: int               # cell (1-235) whose start coincides with the epoch
    saros_cycle0: Fraction          # Saros cycle fraction at the epoch
    games0: Fraction                # Games cycle fraction at the epoch
    callippic0: Fraction            # Callippic cycle fraction at the epoch
    sun_override: float | None      # mean Sun longitude forced by the author's calibration
    egyptian_override: tuple[int, int] | None


def anomaly_turns(alpha_turns: float, e: float, eccentric: bool) -> float:
    """Pin-and-slot output in turns.

    eccentric: Hipparchan eccentric model (Moon, Sun), alpha from apogee, the
    true position lags after apogee. Otherwise an epicycle with the planet at
    the far point when alpha = 0 (superior conjunction).
    """
    a = alpha_turns * 2 * math.pi
    q = math.atan2(e * math.sin(a), 1 + e * math.cos(a))
    return (-q if eccentric else q) / (2 * math.pi)


def _epochs() -> list[Epoch]:
    # 205 BC: Saros dial month 1 starts with the New Moon of 28 April 205 BC
    # (Carman & Evans 2014, Freeth 2014); the Corinthian calendar and the Games
    # cycle start four lunar months later (Iversen 2017, Jones 2017). The dial
    # cells begin 2 EYu (first crescent) after New Moon in the Eclipse Year Model.
    nm = mean_new_moon(julian_day(-204, 4, 28.5)) - DELTA_T_DAYS
    four_months = Fraction(4) * Fraction(19, 235)       # years
    e205 = Epoch(0, '205 BC (Freeth, Carman-Evans, Jones)', nm, 232,
                 Fraction(-2, 38 * 223), 1 - four_months * GAMES, 1 - four_months * CALLIPPIC,
                 None, None)
    # 178 BC: Voulgaris et al. 2022. Metonic cell 1 and the Callippic cycle start
    # on 23 December 178 BC, the day after the annular eclipse New Moon of 22
    # December; the Saros pointer is at cell 2, the Sun at the first day of
    # Capricorn and at Athyr 18, the Games pointer 34 degrees into year 3.
    nm = mean_new_moon(julian_day(-177, 12, 22.5)) - DELTA_T_DAYS
    e178 = Epoch(1, '178 BC (Voulgaris et al.)', nm, 1,
                 Fraction(1, 223), Fraction(2 * 90 + 34, 360), Fraction(0),
                 270.0, (2, 18))
    return [e205, e178]


EPOCHS = _epochs()


def epoch_phases(epoch: Epoch) -> dict[str, Fraction]:
    """Epoch phase of every shaft, in turns, as exact fractions of 2^24."""
    el = mean_elements(epoch.jd_utc + DELTA_T_DAYS)
    sun = epoch.sun_override if epoch.sun_override is not None else el['sun']
    moon = sun                      # mean New Moon: mean elongation zero
    deg = lambda d: Fraction(round((d % 360) / 360 * (1 << 24)), 1 << 24)
    syn = lambda p: deg(el[p] - el['sun'])
    phases = {
        'sun_mean': deg(sun),
        'sun_anomaly': deg(sun - SUN_APOGEE_DEG),
        'moon_mean': deg(moon),
        'moon_anomaly': deg(el['moon_anomaly'] + 180),
        'nodes': deg(el['node']),
        'metonic': Fraction(epoch.metonic_cell - 1, 235),
        'saros': epoch.saros_cycle0 % 1,
        'exeligmos': (epoch.saros_cycle0 / 3) % 1,
        'games': epoch.games0 % 1,
        'callippic': epoch.callippic0 % 1,
        'mercury': syn('mercury'),
        'venus': syn('venus'),
        'mars': deg(el['mars']),
        'jupiter': deg(el['jupiter']),
        'saturn': deg(el['saturn']),
        'apsides': deg(moon - (el['moon_anomaly'] + 180)),
    }
    return phases


def epoch_initial_accumulators(epoch: Epoch) -> list[int]:
    phases = epoch_phases(epoch)
    values = []
    for shaft in SHAFTS:
        modulus = shaft_modulus(shaft)
        f = phases[shaft.name] * modulus
        values.append(int(round(f)) % modulus)
    return values


def epoch_day_fields(epoch: Epoch) -> tuple[int, int]:
    """(Julian Day Number at tick 0, tick offset of the epoch inside that day).

    Civil days change at local midnight. day_count = (ticks + offset) >> 16.
    """
    local = epoch.jd_utc + LOCAL_OFFSET_DAYS + 0.5
    jdn = math.floor(local)
    offset = int(round((local - jdn) * DAY_TICKS))
    return jdn, offset


# ---------------------------------------------------------------------------
# Angles at any time, as the hardware computes them.
# ---------------------------------------------------------------------------
def shaft_fraction(shaft: Shaft, epoch: Epoch, ticks: int) -> Fraction:
    modulus = shaft_modulus(shaft)
    f0 = epoch_initial_accumulators(epoch)[shaft.index]
    return Fraction((f0 + ticks * shaft.rate.numerator) % modulus, modulus)


def positions(epoch: Epoch, ticks: int, b1_teeth: int = 223) -> dict[str, float]:
    """Everything shown on the front dial, in turns of longitude (0..1)."""
    f = {s.name: float(shaft_fraction(s, epoch, ticks)) for s in SHAFTS}
    sun = (f['sun_mean'] + anomaly_turns(f['sun_anomaly'], float(EPICYCLE['sun']), True)) % 1
    moon = (f['moon_mean'] + anomaly_turns(f['moon_anomaly'], float(EPICYCLE['moon']), True)) % 1
    out = {'date': f['sun_mean'], 'sun': sun, 'moon': moon, 'phase': (moon - sun) % 1,
           'node': f['nodes'], 'apogee': f['apsides']}
    for p in ('mercury', 'venus'):
        out[p] = (f['sun_mean'] + anomaly_turns(f[p], float(EPICYCLE[p]), False)) % 1
    for p in ('mars', 'jupiter', 'saturn'):
        alpha = (f['sun_mean'] - f[p]) % 1
        out[p] = (f[p] + anomaly_turns(alpha, float(EPICYCLE[p]), False)) % 1
    out['metonic'] = f['metonic']
    out['saros'] = f['saros']
    out['exeligmos'] = f['exeligmos']
    out['games'] = f['games']
    out['callippic'] = f['callippic']
    out['crank'] = float((Fraction(ticks, int(YEAR_TICKS)) * Fraction(b1_teeth, GEARS['a1'])) % 1)
    return out


# ---------------------------------------------------------------------------
# Calendars and inscriptions.
# ---------------------------------------------------------------------------
ZODIAC = [('ΚΡΙΟΣ', 'ARIES'), ('ΤΑΥΡΟΣ', 'TAURUS'), ('ΔΙΔΥΜΟΙ', 'GEMINI'),
          ('ΚΑΡΚΙΝΟΣ', 'CANCER'), ('ΛΕΩΝ', 'LEO'), ('ΠΑΡΘΕΝΟΣ', 'VIRGO'),
          ('ΧΗΛΑΙ', 'LIBRA'), ('ΣΚΟΡΠΙΟΣ', 'SCORPIO'), ('ΤΟΞΟΤΗΣ', 'SAGITTARIUS'),
          ('ΑΙΓΟΚΕΡΩΣ', 'CAPRICORN'), ('ΥΔΡΟΧΟΟΣ', 'AQUARIUS'), ('ΙΧΘΥΕΣ', 'PISCES')]
EGYPTIAN = [('ΘΩΘ', 'THOTH'), ('ΦΑΩΦΙ', 'PHAOPHI'), ('ΑΘΥΡ', 'ATHYR'), ('ΧΟΙΑΚ', 'CHOIAK'),
            ('ΤΥΒΙ', 'TYBI'), ('ΜΕΧΙΡ', 'MECHIR'), ('ΦΑΜΕΝΩΘ', 'PHAMENOTH'),
            ('ΦΑΡΜΟΥΘΙ', 'PHARMOUTHI'), ('ΠΑΧΩΝ', 'PACHON'), ('ΠΑΥΝΙ', 'PAYNI'),
            ('ΕΠΙΦΙ', 'EPIPHI'), ('ΜΕΣΟΡΗ', 'MESORE'), ('ΕΠΑΓΟΜΕΝΑΙ', 'EPAGOMENAL')]
CORINTHIAN = [('ΦΟΙΝΙΚΑΙΟΣ', 'PHOINIKAIOS'), ('ΚΡΑΝΕΙΟΣ', 'KRANEIOS'),
              ('ΛΑΝΟΤΡΟΠΙΟΣ', 'LANOTROPIOS'), ('ΜΑΧΑΝΕΥΣ', 'MACHANEUS'),
              ('ΔΩΔΕΚΑΤΕΥΣ', 'DODEKATEUS'), ('ΕΥΚΛΕΙΟΣ', 'EUKLEIOS'),
              ('ΑΡΤΕΜΙΣΙΟΣ', 'ARTEMISIOS'), ('ΨΥΔΡΕΥΣ', 'PSYDREUS'),
              ('ΓΑΜΕΙΛΙΟΣ', 'GAMEILIOS'), ('ΑΓΡΙΑΝΙΟΣ', 'AGRIANIOS'),
              ('ΠΑΝΑΜΟΣ', 'PANAMOS'), ('ΑΠΕΛΛΑΙΟΣ', 'APELLAIOS')]
GAMES_DIAL = [('ΙΣΘΜΙΑ ΟΛΥΜΠΙΑ', 'ISTHMIA, OLYMPIA'), ('ΝΕΜΕΑ ΝΑΑ', 'NEMEA, NAA'),
              ('ΙΣΘΜΙΑ ΠΥΘΙΑ', 'ISTHMIA, PYTHIA'), ('ΝΕΜΕΑ ΑΛΙΕΙΑ', 'NEMEA, HALIEIA')]
EXELIGMOS_DIAL = ['', 'Η', 'Ιϛ']          # add 0, 8 or 16 hours
PLANETS = [('ΕΡΜΗΣ', 'MERCURY'), ('ΑΦΡΟΔΙΤΗ', 'VENUS'), ('ΑΡΗΣ', 'MARS'),
           ('ΖΕΥΣ', 'JUPITER'), ('ΚΡΟΝΟΣ', 'SATURN')]
PHASES = ['NEW', 'WAXING CRESCENT', 'FIRST QUARTER', 'WAXING GIBBOUS',
          'FULL', 'WANING GIBBOUS', 'LAST QUARTER', 'WANING CRESCENT']
JULIAN_MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']

# Metonic calendar: years 1,3,6,9,11,14,17 have 13 months (Freeth et al. 2008,
# Jones 2017); the repeated month is the fourth, Machaneus, as attested in
# year 11 (cells 128-129).
INTERCALARY_YEARS = {1, 3, 6, 9, 11, 14, 17}
REPEATED_MONTH = 3              # 0-based index of Machaneus


def metonic_cells() -> list[tuple[int, int, bool]]:
    """For cells 1..235: (year 1-19, month index 0-11, repeated-month flag)."""
    cells = []
    for year in range(1, 20):
        months = list(range(12))
        if year in INTERCALARY_YEARS:
            months.insert(REPEATED_MONTH + 1, REPEATED_MONTH)
        for i, m in enumerate(months):
            cells.append((year, m, year in INTERCALARY_YEARS and i == REPEATED_MONTH + 1))
    assert len(cells) == 235
    return cells


def check_metonic_against_jones():
    """Preserved month sequences, Jones 2017 Table 3 (year, roman months)."""
    cells = metonic_cells()
    attested = {1: (1, 0), 3: (1, 2), 31: (3, 4), 38: (3, 11), 39: (4, 0), 49: (4, 10),
                79: (7, 3), 87: (7, 11), 88: (8, 0), 97: (8, 9), 127: (11, 2), 128: (11, 3),
                129: (11, 3), 130: (11, 4), 137: (11, 11), 138: (12, 0), 143: (12, 5),
                175: (15, 0), 186: (15, 11), 187: (16, 0), 189: (16, 2), 226: (19, 2),
                227: (19, 3), 235: (19, 11)}
    for cell, (year, month) in attested.items():
        got = cells[cell - 1]
        assert got[0] == year and got[1] == month, (cell, got, year, month)


# Eclipse Year Model, Freeth 2014 (Note S3 and main text).
EYU_PER_MONTH = 38
EYU_PER_ECLIPSE_YEAR = 446
NODE_POINTS = (66, 289)          # descending, ascending node points (EYu)
FIRST_CRESCENT = 2               # EYu after New Moon; the dial cells start here


def saros_glyphs() -> list[tuple[bool, bool]]:
    """(lunar, solar) eclipse possibility for Saros months 1..223."""
    def near(pos, point, before, after):
        d = (pos - point) % EYU_PER_ECLIPSE_YEAR
        if d > EYU_PER_ECLIPSE_YEAR // 2:
            d -= EYU_PER_ECLIPSE_YEAR
        return -before <= d <= after
    lunar, solar = [], []
    for m in range(1, 224):
        fm = ((m - 1) * EYU_PER_MONTH + 19 - FIRST_CRESCENT) % EYU_PER_ECLIPSE_YEAR
        nm = ((m - 1) * EYU_PER_MONTH + EYU_PER_MONTH - FIRST_CRESCENT) % EYU_PER_ECLIPSE_YEAR
        dnp, anp = NODE_POINTS
        lunar.append(near(fm, dnp, 20, 20) or near(fm, anp, 20, 20))
        # Before the descending node point the Moon is north of the ecliptic.
        solar.append(near(nm, dnp, 20, 7) or near(nm, anp, 7, 20))
    for m in range(1, 223):          # consecutive month rule
        if lunar[m - 1] and lunar[m]:
            lunar[m] = False
    return list(zip(lunar, solar))


# Surviving glyph months and their eclipse times (Freeth 2014 Table S3B).
PRESERVED_LUNAR_TIMES = {20: (False, 6), 26: (True, 7), 79: (True, 10), 114: (True, 12),
                         125: (True, 2), 131: (False, 2), 137: (True, 5), 172: (False, 6),
                         178: (False, 9), 184: (True, 4), 190: (True, 9)}
PRESERVED_SOLAR_TIMES = {25: (True, 6), 72: (False, 2), 78: (True, 1), 119: (False, 10),
                         125: (True, 3), 131: (False, 9), 137: (True, 12), 172: (True, 12),
                         178: (True, 9), 184: (True, 1)}
PRESERVED_GLYPH_MONTHS = {13, 20, 25, 26, 67, 72, 78, 79, 114, 119, 120, 125, 131, 137,
                          172, 178, 184, 190}


def check_glyphs():
    g = saros_glyphs()
    lunar = {m for m, (l, s) in enumerate(g, 1) if l}
    solar = {m for m, (l, s) in enumerate(g, 1) if s}
    assert len(lunar) == 38 and len(solar) == 28 and len(lunar | solar) == 51
    assert set(PRESERVED_LUNAR_TIMES) <= lunar and set(PRESERVED_SOLAR_TIMES) <= solar
    assert PRESERVED_GLYPH_MONTHS <= (lunar | solar)


def _sun_longitude(epoch: Epoch, t_days: float) -> float:
    years = t_days / float(YEAR_DAYS)
    ph = epoch_phases(epoch)
    mean = float(ph['sun_mean']) + years
    anom = float(ph['sun_anomaly']) + years
    return (mean + anomaly_turns(anom, float(EPICYCLE['sun']), True)) % 1


def _moon_longitude(epoch: Epoch, t_days: float) -> float:
    years = t_days / float(YEAR_DAYS)
    ph = epoch_phases(epoch)
    mean = float(ph['moon_mean']) + years * float(SIDEREAL_MOON)
    anom = float(ph['moon_anomaly']) + years * float(ANOMALISTIC)
    return (mean + anomaly_turns(anom, float(EPICYCLE['moon']), True)) % 1


def syzygy_time(epoch: Epoch, month: int, full: bool) -> float:
    """Days after the epoch of the Mechanism's own true syzygy in Saros month m."""
    mean_days = (month - 1 + (0.5 if full else 1.0)) * float(1 / SYNODIC * YEAR_DAYS)
    target = 0.5 if full else 0.0
    t = mean_days
    for _ in range(8):
        e = (_moon_longitude(epoch, t) - _sun_longitude(epoch, t) - target + 0.5) % 1 - 0.5
        t -= e / float(SYNODIC / YEAR_DAYS)
    return t


def seasonal_hour(epoch: Epoch, t_days: float) -> tuple[bool, int]:
    """(daytime, hour 1-12) in seasonal hours at the local meridian."""
    local = epoch.jd_utc + t_days + LOCAL_OFFSET_DAYS
    frac = (local + 0.5) % 1                     # 0 = local midnight
    lam = _sun_longitude(epoch, t_days) * 2 * math.pi
    decl = math.asin(math.sin(math.radians(OBLIQUITY_DEG)) * math.sin(lam))
    h0 = math.acos(-math.tan(math.radians(LATITUDE_DEG)) * math.tan(decl)) / (2 * math.pi)
    sunrise, sunset = 0.5 - h0, 0.5 + h0
    if sunrise <= frac < sunset:
        return True, int((frac - sunrise) / (2 * h0) * 12) + 1
    night = (frac - sunset) % 1
    return False, int(night / (1 - 2 * h0) * 12) + 1


def glyph_table() -> list[dict]:
    """Per Saros month: flags and hours; preserved inscriptions win."""
    rows = []
    for m, (lunar, solar) in enumerate(saros_glyphs(), 1):
        row = {'month': m, 'lunar': lunar, 'solar': solar}
        if lunar:
            row['lunar_time'] = PRESERVED_LUNAR_TIMES.get(m) or seasonal_hour(EPOCHS[0], syzygy_time(EPOCHS[0], m, True))
        if solar:
            row['solar_time'] = PRESERVED_SOLAR_TIMES.get(m) or seasonal_hour(EPOCHS[0], syzygy_time(EPOCHS[0], m, False))
        rows.append(row)
    return rows


# Parapegma events keyed to the zodiac dial (Bitsakis & Jones 2016 readings
# as given in the standard references; star phases placed at approximate
# longitudes for the latitude of Greece).
PARAPEGMA = [
    (270, 'Α', 'CAPRICORN BEGINS TO RISE'), (270, '', 'WINTER SOLSTICE'),
    (300, 'Δ', 'AQUARIUS BEGINS TO RISE'), (330, 'Η', 'PISCES BEGINS TO RISE'),
    (0, 'Ι', 'ARIES BEGINS TO RISE'), (0, '', 'SPRING EQUINOX'),
    (25, 'Λ', 'HYADES SET IN THE EVENING'), (30, 'Μ', 'TAURUS BEGINS TO RISE'),
    (40, 'Ν', 'LYRA RISES IN THE EVENING'), (48, 'Ξ', 'PLEIADES RISE IN THE MORNING'),
    (55, 'Ο', 'HYADES RISE IN THE MORNING'), (60, 'Π', 'GEMINI BEGINS TO RISE'),
    (66, 'Ρ', 'ALTAIR RISES IN THE EVENING'), (70, 'Σ', 'ARCTURUS SETS IN THE MORNING'),
    (90, 'Μ', 'CANCER BEGINS TO RISE'), (90, '', 'SUMMER SOLSTICE'),
    (102, 'Ν', 'ORION RISES IN THE MORNING'), (115, 'Ξ', 'SIRIUS RISES IN THE MORNING'),
    (118, 'Ο', 'ALTAIR SETS IN THE MORNING'), (120, 'Π', 'LEO BEGINS TO RISE'),
    (180, 'Α', 'LIBRA BEGINS TO RISE'), (180, '', 'AUTUMN EQUINOX'),
    (210, 'Ε', 'SCORPIO BEGINS TO RISE'), (240, 'Ι', 'SAGITTARIUS BEGINS TO RISE'),
]

# Freeth 2021 Cosmos display: order of the rings from the centre outwards.
COSMOS_RINGS = ['moon', 'mercury', 'venus', 'sun', 'mars', 'jupiter', 'saturn', 'date']


def format_year(year: int) -> str:
    return f'{year} AD' if year > 0 else f'{1 - year} BC'


if __name__ == '__main__':
    check_metonic_against_jones()
    check_glyphs()
    for epoch in EPOCHS:
        jdn, off = epoch_day_fields(epoch)
        y, m, d = julian_calendar(jdn)
        em, ed = egyptian_date(jdn)
        print(f'{epoch.name}: JD {epoch.jd_utc:.3f} UT = {d} {JULIAN_MONTHS[m-1]} {format_year(y)}, '
              f'Egyptian {EGYPTIAN[em][1]} {ed}')
        for shaft in SHAFTS:
            print(f'   {shaft.name:13s} rate {str(shaft.rate):14s} phase {float(epoch_phases(epoch)[shaft.name]):.5f}')
        pos = positions(epoch, 0)
        print('   longitudes:', {k: round(v * 360, 2) for k, v in pos.items() if k in ('date', 'sun', 'moon', 'node', 'mercury', 'venus', 'mars', 'jupiter', 'saturn')})
    rows = glyph_table()
    print('Saros glyph months:', [r['month'] for r in rows if r['lunar'] or r['solar']])
    agree = 0
    for m, (day, hour) in {**PRESERVED_LUNAR_TIMES}.items():
        recon = seasonal_hour(EPOCHS[0], syzygy_time(EPOCHS[0], m, True))
        agree += recon == (day, hour)
        print(f'   lunar {m}: inscribed {"day" if day else "night"} {hour}, model {"day" if recon[0] else "night"} {recon[1]}')
    for m, (day, hour) in PRESERVED_SOLAR_TIMES.items():
        recon = seasonal_hour(EPOCHS[0], syzygy_time(EPOCHS[0], m, False))
        agree += recon == (day, hour)
        print(f'   solar {m}: inscribed {"day" if day else "night"} {hour}, model {"day" if recon[0] else "night"} {recon[1]}')
    print(f'exact matches: {agree}/21')
