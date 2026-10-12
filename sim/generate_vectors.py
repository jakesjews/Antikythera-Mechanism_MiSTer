#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Expected shaft angles and dial readings for the RTL regression.

Each line: ticks epoch 23 shaft fractions, true Sun, true Moon, Metonic cell,
Saros cell. Ticks are reached in the simulator with whole-year, lunar-month
and day nudges, so they are sums of those step sizes.
"""
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import mechanism as M  # noqa: E402
import generate_tables as G  # noqa: E402

YEAR = int(M.YEAR_TICKS)
MONTH = 1935274
DAY = 65536


def shaft_fraction(name: str, rate: Fraction, epoch: M.Epoch, ticks: int) -> Fraction:
    modulus = rate.denominator * YEAR
    phase = M.epoch_phases(epoch).get(name, Fraction(0))
    f0 = int(round(phase * modulus)) % modulus
    num = abs(rate.numerator)
    value = (f0 + ticks * num) % modulus if rate > 0 else (f0 - ticks * num) % modulus
    return Fraction(value, modulus)


def main():
    out = []
    cases = [(0, 0), (0, 1), (DAY, 0), (MONTH, 0), (YEAR, 0), (3 * YEAR + 5 * MONTH + 11 * DAY, 0),
             (19 * YEAR, 0), (-2 * YEAR - 3 * DAY, 0), (40 * YEAR + 7 * MONTH, 1), (-15 * YEAR - MONTH, 1)]
    for ticks, epoch_index in cases:
        epoch = M.EPOCHS[epoch_index]
        fracs = []
        for name, rate in G.HW_SHAFTS:
            f = shaft_fraction(name, rate, epoch, ticks)
            # The hardware keeps 20 bits of the fraction.
            fracs.append(int(f * (1 << 20)) / (1 << 20))
        pos = M.positions(epoch, ticks)
        met_cell = int(M.shaft_fraction(M.SHAFT_BY_NAME['metonic'], epoch, ticks) * 235)
        sar_cell = int(M.shaft_fraction(M.SHAFT_BY_NAME['saros'], epoch, ticks) * 223)
        bodies = ' '.join(f"{pos[b]:.7f}" for b in ('sun', 'moon', 'node', 'mercury', 'venus', 'mars', 'jupiter', 'saturn'))
        out.append(f"{ticks} {epoch_index} " + ' '.join(f'{x:.9f}' for x in fracs) +
                   f" {bodies} {met_cell} {sar_cell}")
    path = Path(__file__).resolve().parents[1] / 'build/vectors.txt'
    path.parent.mkdir(exist_ok=True)
    path.write_text('# ticks epoch fracs[23] sun moon node mercury venus mars jupiter saturn metonic_cell saros_cell\n' + '\n'.join(out) + '\n')
    print(f'{len(out)} vectors written to {path}')


if __name__ == '__main__':
    main()
