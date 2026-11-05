"""blink sounds (2026-11-03): three soft sets, each an 'ask' (Claude needs you) and a 'done' (Claude finished).
Additive synthesis with gentle attacks and exponential decays plus a short room tail; peak -3 dBFS, 48 kHz mono 16-bit.
python make_sounds.py -> <set>_ask.wav / <set>_done.wav in this folder."""
import numpy as np
from scipy.io import wavfile

SR = 48000
MAR = ((1, 1), (4, .25), (10, .06))         # marimba-like bar partials
BELL = ((1, 1), (2.76, .3), (5.4, .12))     # small desk bell
GLASS = ((1, 1), (2, .18), (3, .06))        # soft glass, almost a sine


def note(f, d, a=.006, r=5.0, parts=((1, 1),)):
    n = int(d * SR); t = np.arange(n) / SR; x = np.zeros(n)
    for k, g in parts: x += g * np.sin(2 * np.pi * f * k * t) * np.exp(-t * r * (1 + .6 * (k - 1)))   # upper partials die faster
    return x * np.minimum(1, t / a)


def place(total, items):
    out = np.zeros(int(total * SR))
    for t0, x in items: i = int(t0 * SR); out[i:i + len(x)] += x[:len(out) - i]
    return out


def room(x, mix=.18):
    out = x.copy()
    for d, g in ((.029, .5), (.047, .38), (.071, .27), (.113, .18), (.163, .11)): k = int(d * SR); out[k:] += mix * g * x[:-k]
    return out


def finish(x, name):
    x = room(x); fade = int(.04 * SR); x[-fade:] *= np.linspace(1, 0, fade)
    x = x / np.max(np.abs(x)) * 10 ** (-3 / 20)
    wavfile.write(name, SR, (x * 32767).astype(np.int16))


# 1 "eyes": the n.cloud chime from the videos, A5 then E6 on a warm marimba; done settles back E6 -> A5
finish(place(.9, [(0, note(880, .9, r=6, parts=MAR) * .8), (.11, note(1318.5, .8, r=6, parts=MAR) * .6)]), 'eyes_ask.wav')
finish(place(.8, [(0, note(1318.5, .7, r=7, parts=MAR) * .55), (.1, note(880, .7, r=6, parts=MAR) * .7)]), 'eyes_done.wav')
# 2 "glass": two soft plucks a fourth apart; done is one low tone
finish(place(1.0, [(0, note(659.3, 1.0, a=.01, r=4.5, parts=GLASS)), (.14, note(880, .9, a=.01, r=4.5, parts=GLASS) * .8)]), 'glass_ask.wav')
finish(place(.9, [(0, note(587.3, .9, a=.012, r=4.2, parts=GLASS))]), 'glass_done.wav')
# 3 "bell": a tiny desk bell, double tap to ask, single tap when done
finish(place(1.1, [(0, note(1567.98, 1.1, a=.002, r=4, parts=BELL) * .8), (.16, note(1567.98, 1.0, a=.002, r=4, parts=BELL) * .55)]), 'bell_ask.wav')
finish(place(1.0, [(0, note(1174.66, 1.0, a=.002, r=4.5, parts=BELL) * .7)]), 'bell_done.wav')
print('ok')
