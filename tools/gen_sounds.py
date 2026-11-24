"""Synthesizes Scramble's sound effects as 16-bit mono WAVs.

Usage: python3 tools/gen_sounds.py Scramble/Sounds

Everything is procedural (no external assets, nothing to license):
- pure strikes: a sharp transient + inharmonic metal partials — the
  titanium "crack" of a flushed driver, the crisp click of a pure iron
- ordinary strikes: the same family, duller
- mishits: a buzzy thin "clank" and a heavy fat "thud" + dirt
- putting: wooden-ish putter "tock", cup rattle, lip-out
- landings: fairway/green thump, sand "pff", tree rustle + knock
- gallery: applause (holed putts) and an "ohhh" (lip-outs)
"""
import math, random, wave, struct, os, sys

SR = 44100
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
random.seed(11)


def write(name, samples, gain=1.0):
    peak = max(1e-6, max(abs(s) for s in samples))
    norm = gain / peak
    with wave.open(os.path.join(OUT, name), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * norm)) * 32000))
                               for s in samples))
    print(name, round(len(samples) / SR, 2), "s")


def n_(d):
    return int(SR * d)


def mix(*layers):
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for l in layers:
        for i, s in enumerate(l):
            out[i] += s
    return out


def delay(s, d):
    return [0.0] * n_(d) + s


def env_exp(n, decay, attack=0.0008):
    return [min((i / SR) / attack, 1.0) * math.exp(-decay * i / SR) for i in range(n)]


def partial(freq, dur, amp, decay, attack=0.0005, slide=0.0):
    out, ph = [], 0.0
    for i, e in enumerate(env_exp(n_(dur), decay, attack)):
        ph += 2 * math.pi * (freq + slide * i / SR) / SR
        out.append(amp * e * math.sin(ph))
    return out


def noise(dur, amp, decay, attack=0.0005):
    return [amp * e * random.uniform(-1, 1) for e in env_exp(n_(dur), decay, attack)]


def biquad_bp(x, f, q):
    w0 = 2 * math.pi * f / SR
    alpha = math.sin(w0) / (2 * q)
    b0, b2 = alpha, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    y, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for s in x:
        o = (b0 * s + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, s, y1, o
        y.append(o)
    return y


def lowpass(x, a):
    y, out = 0.0, []
    for s in x:
        y += a * (s - y)
        out.append(y)
    return out


def highpass(x, a):
    lp = lowpass(x, a)
    return [s - l for s, l in zip(x, lp)]


def click(amp=1.0):
    """The ball-on-face transient: 1-2 ms of bright broadband energy."""
    return [amp * s for s in highpass(noise(0.004, 1, 900), 0.3)]


# ---------- strikes ----------

def driver(quality):
    # quality 1 = flushed, 0.6 = ok
    q = quality
    return mix(
        click(1.0 * q),
        partial(1850, 0.35, 0.55 * q, 28),     # titanium ring
        partial(2730, 0.25, 0.38 * q, 38),
        partial(4120, 0.16, 0.26 * q * q, 55),
        partial(6050, 0.08, 0.16 * q * q, 80),
        partial(118, 0.18, 0.7, 30, slide=-120),  # body thump
        [s * 0.25 for s in lowpass(noise(0.05, 1, 60), 0.35)],
    )


def iron(quality):
    q = quality
    return mix(
        click(1.1 * q),
        partial(3150, 0.12, 0.42 * q, 60),     # crisp forged click
        partial(4730, 0.08, 0.3 * q * q, 85),
        partial(2100, 0.1, 0.25, 70),
        partial(180, 0.12, 0.55, 45, slide=-150),
        # Turf after the ball: the "shhk" of a divot.
        delay([s * 0.5 for s in highpass(noise(0.11, 1, 35, attack=0.004), 0.08)], 0.012),
    )


def mishit_thin():
    # Off the toe/blade: dissonant clank with a buzzing rattle.
    base = mix(partial(612, 0.3, 0.6, 16), partial(887, 0.28, 0.5, 18),
               partial(1310, 0.2, 0.35, 24), click(0.6))
    return [s * (0.65 + 0.35 * math.sin(2 * math.pi * 52 * i / SR)) for i, s in enumerate(base)]


def mishit_fat():
    # Heavy thud and a spray of dirt.
    return mix(partial(78, 0.3, 0.9, 16, slide=-40), partial(140, 0.2, 0.5, 28),
               lowpass(noise(0.3, 0.9, 12, attack=0.006), 0.06),
               delay(highpass(noise(0.25, 0.4, 16, attack=0.01), 0.1), 0.03))


def chip():
    return mix(click(0.5), partial(2600, 0.06, 0.3, 90), partial(240, 0.08, 0.4, 50),
               delay(highpass(noise(0.14, 0.5, 30, attack=0.004), 0.1), 0.006))


def putt():
    # Hollow "tock" of a milled putter face.
    return mix(click(0.35), partial(1420, 0.09, 0.5, 60), partial(2240, 0.06, 0.3, 80),
               partial(760, 0.07, 0.25, 70))


def whoosh(dur=0.3):
    n = n_(dur)
    out, y1, y2 = [], 0.0, 0.0
    for i in range(n):
        t = i / n
        bell = math.sin(math.pi * t) ** 3
        cutoff = 0.03 + 0.35 * bell
        x = random.uniform(-1, 1)
        y1 += cutoff * (x - y1)
        y2 += cutoff * (y1 - y2)
        out.append(bell * (y1 - y2 * 0.6))
    return out


# ---------- landings ----------

def land_turf():
    return mix(partial(95, 0.12, 0.8, 38, slide=-50), lowpass(noise(0.1, 0.5, 40), 0.12))


def land_green():
    return mix(partial(130, 0.08, 0.6, 55, slide=-60), lowpass(noise(0.06, 0.25, 60), 0.2))


def land_sand():
    return mix(lowpass(noise(0.35, 1.0, 11, attack=0.004), 0.05),
               highpass(noise(0.2, 0.25, 18, attack=0.004), 0.05))


def tree_hit():
    leaves = [s * (0.5 + 0.5 * math.sin(i / SR * 2 * math.pi * 23))
              for i, s in enumerate(highpass(noise(0.6, 0.6, 6, attack=0.01), 0.15))]
    return mix(partial(410, 0.08, 0.6, 60), partial(680, 0.05, 0.4, 90), click(0.4), leaves)


# ---------- the cup ----------

def cup_drop():
    knocks = []
    t = 0.0
    for k, f in enumerate([980, 860, 760, 700, 660]):
        knocks.append(delay(mix(partial(f, 0.06, 0.6 / (1 + k * 0.4), 70),
                                partial(f * 1.7, 0.04, 0.3 / (1 + k * 0.5), 90)), t))
        t += 0.07 * (0.82 ** k)
    return mix(*knocks, delay(partial(320, 0.3, 0.35, 14), 0.02))


def lip_out():
    # Ball spinning around the rim.
    out = []
    for i in range(n_(0.45)):
        t = i / SR
        rate = 18 - 14 * t
        out.append(math.exp(-5 * t) * math.sin(2 * math.pi * 1250 * t)
                   * (0.5 + 0.5 * math.sin(2 * math.pi * rate * t)))
    return mix([s * 0.5 for s in out], click(0.3))


# ---------- the gallery ----------

def applause(dur=2.4, density=260, amp=0.9):
    n = n_(dur)
    out = [0.0] * n
    for _ in range(int(density * dur)):
        start = random.random() * dur
        swell = math.sin(min(start / dur, 1) * math.pi) ** 0.6
        clap = biquad_bp(noise(0.03, 1, 140), random.uniform(900, 2600), 1.4)
        p = n_(start)
        for j, s in enumerate(clap):
            if p + j < n:
                out[p + j] += s * swell * random.uniform(0.4, 1)
    return [s * amp for s in out]


def crowd_ohh(dur=1.3):
    # Gallery groan: a crowd of voices on the vowel "oh" (F1 ~ 450, F2 ~ 800).
    n = n_(dur)
    voices = [0.0] * n
    for _ in range(18):
        f0 = random.uniform(110, 230)
        vib = random.uniform(4, 6)
        ph = 0.0
        start = random.uniform(0, 0.12)
        for i in range(n):
            t = i / SR
            if t < start:
                continue
            f = f0 * (1 - 0.08 * (t / dur)) * (1 + 0.01 * math.sin(2 * math.pi * vib * t))
            ph += 2 * math.pi * f / SR
            voices[i] += (ph / math.pi) % 2 - 1
    shaped = mix(biquad_bp(voices, 450, 3), [s * 0.6 for s in biquad_bp(voices, 800, 4)])
    env = [math.sin(math.pi * min(i / n, 1)) ** 0.8 * (1 - 0.3 * i / n) for i in range(n)]
    breath = lowpass(noise(dur, 0.6, 0.5, attack=0.2), 0.05)
    return mix([s * e for s, e in zip(shaped, env)], [s * e * 2 for s, e in zip(breath, env)])


def pure_chime():
    return mix(partial(659, 0.4, 0.28, 9, attack=0.012),
               delay(partial(988, 0.5, 0.24, 8, attack=0.012), 0.12))


write("hit_driver_pure.wav", driver(1.0), 0.95)
write("hit_driver.wav", driver(0.6), 0.8)
write("hit_iron_pure.wav", iron(1.0), 0.9)
write("hit_iron.wav", iron(0.6), 0.75)
write("mishit.wav", mishit_fat(), 0.85)
write("mishit_thin.wav", mishit_thin(), 0.75)
write("hit_chip.wav", chip(), 0.7)
write("hit_putt.wav", putt(), 0.7)
write("whoosh.wav", whoosh(), 0.6)
write("land_turf.wav", land_turf(), 0.6)
write("land_green.wav", land_green(), 0.5)
write("land_sand.wav", land_sand(), 0.6)
write("tree_hit.wav", tree_hit(), 0.6)
write("cup_drop.wav", cup_drop(), 0.85)
write("lip_out.wav", lip_out(), 0.6)
write("applause.wav", applause(), 0.75)
write("applause_big.wav", applause(3.4, 420, 1.0), 0.9)
write("crowd_ohh.wav", crowd_ohh(), 0.7)
write("pure_chime.wav", pure_chime(), 0.5)
write("ui_lock.wav", partial(1250, 0.045, 0.35, 110), 0.35)
write("splash.wav", mix(partial(220, 0.15, 0.5, 40, slide=-160),
                        delay(whoosh(0.5), 0.03)), 0.8)
