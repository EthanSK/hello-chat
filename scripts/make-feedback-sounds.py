#!/usr/bin/env python3
"""Reproduce HelloChat's short original cues. No speech synthesis or playback.

Usage: make-feedback-sounds.py [output-directory]   (default: Resources/Sounds)
Every phrase has a cue (PhraseSlot.cue in FeedbackSounds.swift). The original chimes below are
unchanged; command cues use deliberately different, playful shapes so each can be learned by ear.
"""
import math
from pathlib import Path
import struct
import sys
import wave

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Resources" / "Sounds"
root.mkdir(parents=True, exist_ok=True)
rate = 44100
for name, notes in [("Wake", (659.25, 987.77)), ("Ended", (659.25, 439.99)),
                    ("MicrophoneDetected", (784.0,)),
                    ("MicrophoneMuted", (523.25, 349.23)),
                    ("MicrophoneUnmuted", (349.23, 523.25)),
                    ("SpeakersMuted", (440.0, 293.66)),
                    ("SpeakersUnmuted", (293.66, 440.0))]:
    values = []
    for index in range(int(rate * 0.36)):
        t = index / rate
        value = 0.0
        for offset, frequency in zip((0.0, 0.105), notes):
            age = t - offset
            if age >= 0:
                envelope = min(1, age / 0.008) * math.exp(-age * 18)
                value += 0.22 * envelope * (math.sin(2 * math.pi * frequency * age) + 0.15 * math.sin(2 * math.pi * frequency * 2 * age))
        # A short tail fade keeps the end click-free.
        value *= min(1, (0.36 - t) / 0.025)
        values.append(struct.pack('<h', round(max(-1, min(1, value)) * 32767)))
    with wave.open(str(root / f"{name}.wav"), 'wb') as out:
        out.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        out.writeframes(b''.join(values))

# Command cues ---------------------------------------------------------------------------------
SQUAREISH = ((1, 1.0), (3, 0.3), (5, 0.12))  # Soft retro square: video.
WOOD = ((1, 1.0), (2.76, 0.45), (5.4, 0.15))  # Inharmonic knock: switching.
SPRING = ((1, 1.0), (2, 0.35), (3, 0.1))     # Springy: opening.
SWEEP = ((1, 1.0), (2, 0.2))                 # Smooth glide: zoom.
BUBBLE = ((1, 1.0), (1.5, 0.24))             # Hollow bubble: alternate speaker silence.


def loudness(samples):
    """Loudest 100 ms RMS, so short and long cues sit at the same level as the chimes."""
    window = int(rate * 0.1)
    return max(math.sqrt(sum(v * v for v in samples[start:start + window]) / window)
               for start in range(0, max(1, len(samples) - window + 1), window // 4))


with wave.open(str(root / "MicrophoneMuted.wav"), 'rb') as reference:
    data = reference.readframes(reference.getnframes())
target = loudness([v / 32767 for v in struct.unpack(f'<{len(data) // 2}h', data)])


def voice(duration, frequency, partials, envelope):
    """frequency(t) and envelope(t) shape one voice; phase is accumulated so glides stay smooth."""
    phase, samples = 0.0, []
    for index in range(int(rate * duration)):
        t = index / rate
        phase += frequency(t) / rate
        samples.append(envelope(t) * sum(level * math.sin(2 * math.pi * multiple * phase) for multiple, level in partials))
    return samples


def hits(duration, starts, frequencies, partials, decay, length):
    """Short separate notes, such as the two pause bars or a tick-tock."""
    samples = []
    for index in range(int(rate * duration)):
        t, value = index / rate, 0.0
        for start, frequency in zip(starts, frequencies):
            age = t - start
            if 0 <= age < length:
                shape = min(1, age / 0.002, (length - age) / 0.012) * math.exp(-age * decay)
                value += shape * sum(level * math.sin(2 * math.pi * frequency * multiple * age) for multiple, level in partials)
        samples.append(value)
    return samples


def write(name, samples):
    duration = len(samples) / rate
    faded = [v * min(1, (i / rate) / 0.003, (duration - i / rate) / 0.02) for i, v in enumerate(samples)]
    scale = min(target / loudness(faded), 0.6 / max(abs(v) for v in faded))
    with wave.open(str(root / f"{name}.wav"), 'wb') as out:
        out.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        out.writeframes(b''.join(struct.pack('<h', round(max(-1, min(1, v * scale)) * 32767)) for v in faded))


# Pause video: two identical blips, like the two bars of a pause symbol.
write("VideoPaused", hits(0.22, (0.0, 0.12), (587.33, 587.33), SQUAREISH, 6, 0.07))
# Play video: one retro note that bends up a fifth and holds, like pressing play.
write("VideoPlayed", voice(0.3, lambda t: 392.0 * 1.5 ** min(1, t / 0.08), SQUAREISH,
                           lambda t: math.exp(-max(0.0, t - 0.1) * 10)))
# Switch app: a high-low wooden tick-tock, flipping from one app to another.
write("SwitchApp", hits(0.22, (0.0, 0.085), (1318.51, 987.77), WOOD, 50, 0.13))
# Open app: a springy boing that pops up and wobbles.
write("OpenApp", voice(0.4, lambda t: 392.0 * (0.6 + 0.4 * min(1, t / 0.03)) * (1 + 0.18 * math.exp(-t * 7) * math.sin(2 * math.pi * 15 * t)),
                       SPRING, lambda t: math.exp(-t * 6)))
# Zoom in / out: a smooth whoop sweeping up or down more than two octaves.
write("ZoomIn", voice(0.34, lambda t: 300.0 * 5 ** (t / 0.34), SWEEP, lambda t: math.sin(math.pi * t / 0.34) ** 0.7))
write("ZoomOut", voice(0.34, lambda t: 1500.0 / 5 ** (t / 0.34), SWEEP, lambda t: math.sin(math.pi * t / 0.34) ** 0.7))
# Silent is a bubble that drops, then jumps up and pops. Silence keeps its original chime.
write("Silent", voice(0.26, lambda t: (1050.0 / 4 ** (t / 0.085)) if t < 0.085 else (760.0 * 2 ** ((t - 0.085) / 0.175)),
                      BUBBLE, lambda t: math.exp(-10 * t)))
