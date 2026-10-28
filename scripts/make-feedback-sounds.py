#!/usr/bin/env python3
"""Reproduce HelloChat's short original cues. No speech synthesis or playback."""
import math
from pathlib import Path
import struct
import wave

root = Path(__file__).resolve().parent.parent / "Resources" / "Sounds"
root.mkdir(parents=True, exist_ok=True)
rate = 44100
for name, notes in [("Wake", (659.25, 987.77)), ("Ended", (659.25, 439.99))]:
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
