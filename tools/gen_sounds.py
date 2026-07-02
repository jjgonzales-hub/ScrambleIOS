"""Synthesizes Scramble's sound effects as 16-bit mono WAVs.

Usage: python3 tools/gen_sounds.py Scramble/Sounds

Design language: soft, organic, understated — matches the muted art
direction. No arcade bleeps except the tiny UI tick.
"""
import math, random, wave, struct, os, sys

SR = 44100
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
random.seed(7)


def write(name, samples):
    with wave.open(os.path.join(OUT, name), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in samples
        )
        w.writeframes(frames)
    print(name, len(samples) / SR, "s")


def seconds(d):
    return int(SR * d)


def mix(*layers):
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for l in layers:
        for i, s in enumerate(l):
            out[i] += s
    return out


def sine_decay(freq, dur, amp=1.0, decay=18.0, freq_slide=0.0, attack=0.002):
    n = seconds(dur)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        f = freq + freq_slide * t
        phase += 2 * math.pi * f / SR
        env = min(t / attack, 1.0) * math.exp(-decay * t)
        out.append(amp * env * math.sin(phase))
    return out


def noise_burst(dur, amp=1.0, decay=30.0, lowpass=0.15, attack=0.001):
    n = seconds(dur)
    out = []
    y = 0.0
    for i in range(n):
        t = i / SR
        x = random.uniform(-1, 1)
        y += lowpass * (x - y)
        env = min(t / attack, 1.0) * math.exp(-decay * t)
        out.append(amp * env * y)
    return out


def whoosh(dur, amp=0.8):
    """Band-swept noise: quiet -> peak -> quiet, cutoff rising then falling."""
    n = seconds(dur)
    out = []
    y = 0.0
    for i in range(n):
        t = i / n
        bell = math.sin(math.pi * t) ** 2
        cutoff = 0.02 + 0.3 * bell
        x = random.uniform(-1, 1)
        y += cutoff * (x - y)
        out.append(amp * bell * y)
    return out


def delay(samples, d):
    return [0.0] * seconds(d) + samples


# Driver: deep punchy thump + tiny click
write("hit_driver.wav", mix(
    sine_decay(150, 0.30, amp=0.9, decay=26, freq_slide=-260),
    noise_burst(0.05, amp=0.55, decay=90, lowpass=0.5),
))

# Iron: brighter thock
write("hit_iron.wav", mix(
    sine_decay(240, 0.22, amp=0.75, decay=34, freq_slide=-320),
    noise_burst(0.04, amp=0.45, decay=110, lowpass=0.45),
))

# Chip: soft click + turf brush
write("hit_chip.wav", mix(
    sine_decay(330, 0.12, amp=0.5, decay=55),
    noise_burst(0.16, amp=0.3, decay=26, lowpass=0.12),
))

# Putt: tiny tick
write("hit_putt.wav", mix(
    sine_decay(900, 0.05, amp=0.4, decay=120),
    noise_burst(0.02, amp=0.2, decay=200, lowpass=0.6),
))

# Mishit: dull thud, no ring
write("mishit.wav", mix(
    sine_decay(90, 0.25, amp=0.85, decay=22, freq_slide=-60),
    noise_burst(0.12, amp=0.4, decay=40, lowpass=0.08),
))

# Swing whoosh (played on downswing)
write("whoosh.wav", whoosh(0.32, amp=0.7))

# Cup drop: three descending plastic knocks + settle
write("cup_drop.wav", mix(
    sine_decay(520, 0.08, amp=0.6, decay=70),
    delay(sine_decay(430, 0.08, amp=0.55, decay=70), 0.09),
    delay(sine_decay(340, 0.16, amp=0.5, decay=45), 0.18),
    delay(noise_burst(0.1, amp=0.2, decay=50, lowpass=0.3), 0.18),
))

# Splash: soft heavy plunk + wash
write("splash.wav", mix(
    sine_decay(220, 0.15, amp=0.5, decay=40, freq_slide=-160),
    delay(whoosh(0.5, amp=0.55), 0.03),
))

# UI lock tick (power lock)
write("ui_lock.wav", sine_decay(1250, 0.045, amp=0.35, decay=110))

# Pure chime: two soft notes (E5 -> B5), gentle attack
write("pure_chime.wav", mix(
    sine_decay(659, 0.4, amp=0.28, decay=9, attack=0.012),
    delay(sine_decay(988, 0.5, amp=0.24, decay=8, attack=0.012), 0.12),
))
