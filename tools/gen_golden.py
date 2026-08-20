#!/usr/bin/env python3
"""Generate the golden fixtures the Swift POS tests check themselves against.

Two files are produced in Tests/RPPGCoreTests/Fixtures:

  synthetic_C.csv   frameCount,t,cR,cG,cB  — a synthetic ROI mean sequence
  golden_pos.csv    every POS intermediate computed from it

The POS block below is a transcription of rPPG_test.m lines 137-170 into plain
Python floats (which are IEEE-754 doubles, same as MATLAB's). It exists so the
fixtures can be produced and re-produced without MATLAB; matlab/pos_reference.m is
the authority, and running it on synthetic_C.csv must reproduce golden_pos.csv.

Deliberately dependency-free: no numpy, so it runs anywhere.

Usage:  python3 tools/gen_golden.py
"""

import math
import os

LAMBDA1 = 0.99
LAMBDA2 = 0.9
EPSILON = 1.0e-09

FPS = 30.0
DURATION_S = 40.0

SKIN_DC = (180.0, 140.0, 130.0)
# Normalised blood-volume-pulse direction (de Haan & van Leest, 2014).
PULSE_DIRECTION = (0.33, 0.77, 0.53)
PULSE_HZ = 1.2            # 72 bpm
PULSE_AMPLITUDE = 0.01    # 1% of DC, roughly what a face gives at room light

# Channel-common disturbances POS is supposed to cancel. Both are far larger than
# the pulse on purpose.
BREATHING_HZ = 0.25       # 15 breaths/min, head motion modulating the illumination
BREATHING_AMPLITUDE = 0.03
DRIFT_HZ = 0.05
DRIFT_AMPLITUDE = 0.05

NOISE_AMPLITUDE = 0.0005  # per-channel sensor noise, fraction of DC


class Xorshift:
    """Tiny deterministic PRNG so the fixture is reproducible everywhere."""

    def __init__(self, seed):
        self.state = seed or 1

    def next_signed_unit(self):
        s = self.state
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        self.state = s
        return (s % 20001) / 10000.0 - 1.0


def make_channel_sequence():
    """C(t) = I(t) * (dc + dc*a*p(t)*direction + dc*noise)."""
    count = int(DURATION_S * FPS)
    rng = Xorshift(0x5EED)
    rows = []
    for index in range(count):
        t = index / FPS
        intensity = (
            1.0
            + BREATHING_AMPLITUDE * math.sin(2 * math.pi * BREATHING_HZ * t)
            + DRIFT_AMPLITUDE * math.sin(2 * math.pi * DRIFT_HZ * t)
        )
        pulse = math.sin(2 * math.pi * PULSE_HZ * t)
        channels = []
        for dc, direction in zip(SKIN_DC, PULSE_DIRECTION):
            noise = NOISE_AMPLITUDE * rng.next_signed_unit()
            channels.append(intensity * (dc + dc * PULSE_AMPLITUDE * pulse * direction + dc * noise))
        rows.append((index, t, channels[0], channels[1], channels[2]))
    return rows


def run_pos(channel_rows, lambda1=LAMBDA1, lambda2=LAMBDA2, epsilon=EPSILON):
    """rPPG_test.m lines 137-170, transcribed. Do not restructure the arithmetic."""
    c_mean = None
    s_mean = None
    s_var = None
    h_mean = None
    rppg = 0.0

    out = []
    for (_, _, cr, cg, cb) in channel_rows:
        c = (cr, cg, cb)

        # temporal normalization
        if c_mean is None:
            c_mean = c
        else:
            c_mean = tuple(lambda1 * m + (1 - lambda1) * x for m, x in zip(c_mean, c))

        # projection: S = [0 1 -1; -2 1 1] * (C./Cmean)
        cn = tuple(x / m for x, m in zip(c, c_mean))
        s = (cn[1] - cn[2], (-2 * cn[0] + cn[1]) + cn[2])

        # tunning
        if s_mean is None:
            s_mean = s
        else:
            s_mean = tuple(lambda1 * m + (1 - lambda1) * x for m, x in zip(s_mean, s))

        deviation = tuple((x - m) * (x - m) for x, m in zip(s, s_mean))
        if s_var is None:
            s_var = deviation
        else:
            s_var = tuple(lambda1 * v + (1 - lambda1) * d for v, d in zip(s_var, deviation))

        s_std = tuple(math.sqrt(v) for v in s_var)

        # h = S(1)/(Sstd(1)+1e-9) + 1/(Sstd(2)+1e-9)*S(2)
        # The asymmetry (divide vs reciprocal-then-multiply) is the reference's, kept
        # so the last-bit behaviour matches.
        h = s[0] / (s_std[0] + epsilon) + (1 / (s_std[1] + epsilon)) * s[1]

        # overlap-adding
        if h_mean is None:
            h_mean = h
        else:
            h_mean = lambda2 * h_mean + (1 - lambda2) * h

        rppg = rppg + (h - h_mean)

        out.append(
            list(c) + list(c_mean) + list(cn) + list(s) + list(s_mean)
            + list(s_var) + list(s_std) + [h, h_mean, rppg]
        )
    return out


def fmt(value):
    return "%.17g" % value


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    fixtures = os.path.join(here, "..", "Tests", "RPPGCoreTests", "Fixtures")
    fixtures = os.path.normpath(fixtures)
    os.makedirs(fixtures, exist_ok=True)

    rows = make_channel_sequence()

    input_path = os.path.join(fixtures, "synthetic_C.csv")
    with open(input_path, "w") as handle:
        handle.write("frameCount,t,cR,cG,cB\n")
        for (index, t, cr, cg, cb) in rows:
            handle.write("%d,%s,%s,%s,%s\n" % (index, fmt(t), fmt(cr), fmt(cg), fmt(cb)))

    names = [
        "cR", "cG", "cB", "cMeanR", "cMeanG", "cMeanB", "cNormR", "cNormG", "cNormB",
        "s1", "s2", "sMean1", "sMean2", "sVar1", "sVar2", "sStd1", "sStd2",
        "h", "hMean", "rppg",
    ]
    golden = run_pos(rows)
    golden_path = os.path.join(fixtures, "golden_pos.csv")
    with open(golden_path, "w") as handle:
        handle.write(",".join(names) + "\n")
        for row in golden:
            handle.write(",".join(fmt(v) for v in row) + "\n")

    h_values = [row[17] for row in golden]
    rppg_values = [row[19] for row in golden]
    print("frames                : %d (%.1f s at %.0f fps)" % (len(rows), DURATION_S, FPS))
    print("first step  h, rppg   : %g, %g" % (h_values[0], rppg_values[0]))
    print("max |h|               : %g" % max(abs(v) for v in h_values))
    print("rppg range            : %g .. %g" % (min(rppg_values), max(rppg_values)))
    print("wrote %s" % input_path)
    print("wrote %s" % golden_path)


if __name__ == "__main__":
    main()
