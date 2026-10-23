#!/usr/bin/env python3
"""Compose TokenLens' original 32-second / 120 BPM promotional soundtrack.

All sound is synthesized here. No external samples, melodies, or recordings.
Requires Python 3 + numpy. Run from any directory; WAV is written to public/audio.
"""
from pathlib import Path
import json
import math
import wave

import numpy as np

SR = 48000
DURATION = 32.0
BEAT = 0.5
RNG = np.random.default_rng(321120)
mix = np.zeros((int(SR * DURATION), 2), dtype=np.float64)
music = np.zeros_like(mix)
drums = np.zeros_like(mix)


def hz(note):
    return 440.0 * 2.0 ** ((note - 69) / 12.0)


def stereo(signal, pan=0.0, gain=1.0):
    angle = (pan + 1.0) * math.pi / 4
    return signal[:, None] * np.array([math.cos(angle), math.sin(angle)]) * gain


def add(bus, signal, when, pan=0.0, gain=1.0):
    signal = stereo(signal, pan, gain) if signal.ndim == 1 else signal * gain
    start = int(round(when * SR))
    left = max(0, -start)
    end = min(len(bus), start + len(signal))
    if end > max(0, start):
        bus[max(0, start):end] += signal[left:left + end - max(0, start)]


def time_axis(duration):
    return np.arange(int(duration * SR), dtype=np.float64) / SR


def pluck(note, duration=0.75, softness=1.0):
    t = time_axis(duration)
    f = hz(note)
    env = (1.0 - np.exp(-t / 0.004)) * np.exp(-t / (0.15 * softness))
    tone = np.sin(2 * np.pi * f * t)
    tone += 0.24 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t / 0.09)
    tone += 0.075 * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t / 0.035)
    tone += 0.025 * np.sin(2 * np.pi * 5 * f * t) * np.exp(-t / 0.018)
    return tone * env * 0.18


def bass(note, duration=0.30):
    t = time_axis(duration)
    f = hz(note)
    phase = 2 * np.pi * f * (t + 0.0003 * (1 - np.exp(-t / 0.018)))
    # The second harmonic supplies presence on small speakers without a buzzy saw.
    tone = np.sin(phase) + 0.24 * np.sin(2 * phase) + 0.07 * np.sin(3 * phase)
    env = (1 - np.exp(-t / 0.007)) * np.exp(-t / 0.22)
    env *= np.minimum(1, np.maximum(0, (duration - t) / 0.025))
    return tone * env * 0.27


def pad(notes, duration=2.8):
    t = time_axis(duration)
    env = (1 - np.exp(-t / 0.36)) * np.minimum(1, np.maximum(0, (duration - t) / 0.8))
    out = np.zeros((len(t), 2))
    for i, note in enumerate(notes):
        f = hz(note)
        left = np.sin(2 * np.pi * f * 0.9992 * t + i * 0.35)
        right = np.sin(2 * np.pi * f * 1.0008 * t + i * 0.35)
        left += 0.08 * np.sin(2 * np.pi * f * 2 * t)
        right += 0.08 * np.sin(2 * np.pi * f * 2.001 * t)
        out += np.column_stack((left, right))
    return out * env[:, None] * (0.045 / len(notes))


def band_noise(duration, low, high):
    n = int(SR * duration)
    bins = np.fft.rfftfreq(n, 1 / SR)
    white = RNG.normal(0, 1, n)
    spectrum = np.fft.rfft(white)
    # Soft frequency edges keep synthesized drums rounded, not harsh.
    mask = np.clip((bins - low) / max(100, low * 0.4), 0, 1)
    mask *= np.clip((high - bins) / max(200, high * 0.15), 0, 1)
    out = np.fft.irfft(spectrum * mask, n=n)
    return out / max(np.std(out), 1e-9)


def kick():
    t = time_axis(0.36)
    # Integral of an exponential pitch sweep: a soft, compact dance kick.
    phase = 2 * np.pi * (48 * t + 70 * 0.023 * (1 - np.exp(-t / 0.023)))
    body = np.sin(phase) * np.exp(-t / 0.095)
    click = np.sin(2 * np.pi * 1250 * t) * np.exp(-t / 0.003) * 0.08
    attack = 1 - np.exp(-t / 0.001)
    return (body + click) * attack * 0.43


def clap():
    t = time_axis(0.22)
    noise = band_noise(0.22, 450, 5200)
    env = np.exp(-t / 0.045)
    env += 0.55 * np.exp(-np.maximum(t - 0.011, 0) / 0.028) * (t >= 0.011)
    env += 0.36 * np.exp(-np.maximum(t - 0.023, 0) / 0.028) * (t >= 0.023)
    env *= 1 - np.exp(-t / 0.0018)
    body = np.sin(2 * np.pi * 185 * t) * np.exp(-t / 0.025) * 0.23
    return (noise * env + body) * 0.08


def hat(opened=False):
    duration = 0.18 if opened else 0.075
    t = time_axis(duration)
    noise = band_noise(duration, 4300, 10500)
    env = np.exp(-t / (0.038 if opened else 0.014)) * (1 - np.exp(-t / 0.001))
    metal = (np.sin(2 * np.pi * 6123 * t) + np.sin(2 * np.pi * 8129 * t)) * 0.06
    return (noise + metal) * env * (0.037 if opened else 0.031)


def bell(note, duration=1.8):
    t = time_axis(duration)
    f = hz(note)
    signal = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.50)
    signal += 0.18 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t / 0.22)
    signal += 0.045 * np.sin(2 * np.pi * f * 3 * t) * np.exp(-t / 0.07)
    return signal * (1 - np.exp(-t / 0.003)) * 0.16


CHORDS = [
    [49, 56, 59, 63, 64],  # C#m9
    [45, 52, 56, 59, 61],  # Amaj9
    [40, 52, 56, 59, 63],  # Emaj7
    [47, 54, 59, 61, 63],  # Badd9
]
ROOTS = [37, 33, 40, 35]
MELODIES = [
    [73, 76, 80, 76, 78, 76, 71, 73],
    [73, 76, 80, 83, 80, 76, 73, 71],
    [71, 76, 78, 80, 78, 76, 75, 71],
    [75, 78, 83, 78, 80, 78, 75, 73],
]

for bar in range(16):
    start = bar * 2.0
    chord_index = bar % 4
    final = bar >= 15
    # A brighter C#m9 at the finale resolves the four-chord loop deliberately.
    if final:
        chord_index = 0
    add(music, pad(CHORDS[chord_index], duration=3.8 if final else 2.8), start,
        gain=0.60 if bar < 2 else 1.0)

    melody = MELODIES[chord_index]
    if bar < 2:
        positions = [0.0, 0.75, 1.5]
    elif final:
        positions = [0.0, 0.25, 0.50]
    else:
        positions = [0.0, 0.375, 0.75, 1.0, 1.375, 1.75]
    for j, pos in enumerate(positions):
        note = melody[(j + (2 if bar >= 8 else 0)) % len(melody)]
        gain = 0.80 if bar < 2 else (0.83 if bar in [5, 8, 11] else 1.0)
        add(music, pluck(note, softness=1.3 if final else 1.0), start + pos,
            pan=(-0.32 if j % 2 == 0 else 0.32), gain=gain)
    # Eighth-note bass syncopation creates bounce, with space before the next kick.
    if not final:
        for j, pos in enumerate([0.0, 0.75, 1.0, 1.50, 1.75]):
            if bar == 0 and j > 1:
                continue
            note = ROOTS[chord_index] + (12 if j == 4 and bar > 1 else 0)
            add(music, bass(note), start + pos, gain=0.75 if bar < 2 else 1.0)
    else:
        add(music, bass(37, duration=0.70), start)

    for b in range(4):
        if final and b > 0:
            continue
        when = start + b * BEAT
        add(drums, kick(), when, gain=0.72 if bar < 2 else 1.0)
        if b % 2 == 1 and bar >= 1:
            add(drums, clap(), when, pan=0.02, gain=0.86)
        if bar >= 2 and not final:
            add(drums, hat(opened=b % 2 == 0), when + 0.25,
                pan=-0.12 if b % 2 == 0 else 0.15)
            if bar in [3, 7, 11, 13, 14]:
                add(drums, hat(), when + 0.387, pan=0.28, gain=0.55)

    # Tiny warm pickups at the end of four-bar phrases; no noisy risers.
    if bar in [3, 7, 11]:
        for j, note in enumerate([71, 73, 76, 80]):
            add(music, pluck(note, duration=0.40), start + 1.5 + j * 0.125,
                pan=-0.45 + j * 0.30, gain=0.65)

# Product completion at frame 960 / 16 seconds: an original ascending triad.
for j, note in enumerate([76, 80, 83]):
    add(music, bell(note), 16.0 + j * 0.125, pan=-0.18 + j * 0.18, gain=0.70)

# Stereo call-and-answer accents for the Mac / Windows handoff.
add(music, bell(80, 1.1), 22.0, pan=-0.48, gain=0.45)
add(music, bell(83, 1.1), 24.0, pan=0.48, gain=0.45)
for j, note in enumerate([73, 76, 80]):
    add(music, bell(note, 1.8), 26.0 + 0.08 * j, pan=-0.2 + 0.2 * j, gain=0.40)

# Gentle ducking around each kick gives the melodic field a soft breathing pulse.
t = np.arange(len(mix)) / SR
beat_phase = np.mod(t, BEAT)
duck = 1.0 - 0.22 * np.exp(-beat_phase / 0.085)
music *= duck[:, None]

# A restrained ping-pong echo and diffuse tail widen the plucks. Deterministic,
# fully offline, and without a dependency on an external DAW or sample library.
wet = np.zeros_like(music)
for delay, gain, swap in [(0.375, 0.15, True), (0.75, 0.06, False),
                           (0.067, 0.035, True), (0.113, 0.024, False),
                           (0.191, 0.018, True)]:
    samples = int(delay * SR)
    wet[samples:] += music[:-samples, ::-1] * gain if swap else music[:-samples] * gain
mix = drums + music + wet

# Fade only at the physical endpoints: preserve all visual beats through 30s,
# then let the final harmony settle in the remaining two seconds.
fade_in = np.minimum(1.0, t / 0.008)
fade_out = np.clip((DURATION - t) / 1.35, 0.0, 1.0) ** 1.5
mix *= (fade_in * fade_out)[:, None]
mix = np.tanh(mix * 1.05) / np.tanh(1.05)
mix *= 10 ** (-1.0 / 20) / np.max(np.abs(mix))

target = Path(__file__).resolve().parents[1] / "public" / "audio" / "tokenlens-groove.wav"
target.parent.mkdir(parents=True, exist_ok=True)
pcm = np.round(mix * 32767).astype("<i2")
with wave.open(str(target), "wb") as writer:
    writer.setnchannels(2)
    writer.setsampwidth(2)
    writer.setframerate(SR)
    writer.writeframes(pcm.tobytes())

report = {
    "duration_seconds": len(mix) / SR,
    "sample_rate": SR,
    "channels": 2,
    "tempo_bpm": 120,
    "beats": 64,
    "bars": 16,
    "peak_dbfs": round(20 * math.log10(np.max(np.abs(mix))), 3),
    "rms_dbfs": round(20 * math.log10(np.sqrt(np.mean(mix ** 2))), 3),
    "completion_chime_seconds": 16.0,
    "visual_landmarks_seconds": [0, 4, 10, 16, 22, 26, 32],
    "copyright": "Original procedural composition for TokenLens. No external samples or referenced melody.",
    "license": "The user may use, modify, distribute, and synchronize this generated soundtrack for TokenLens promotion, including commercial use.",
}
print(json.dumps(report, ensure_ascii=False, indent=2))
