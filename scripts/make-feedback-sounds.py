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


def write(name, samples, gain=1.0):
    duration = len(samples) / rate
    faded = [v * min(1, (i / rate) / 0.003, (duration - i / rate) / 0.02) for i, v in enumerate(samples)]
    scale = min(target / loudness(faded), 0.6 / max(abs(v) for v in faded)) * gain
    with wave.open(str(root / f"{name}.wav"), 'wb') as out:
        out.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        out.writeframes(b''.join(struct.pack('<h', round(max(-1, min(1, v * scale)) * 32767)) for v in faded))


# Pause video: two identical blips, like the two bars of a pause symbol.
write("VideoPaused", hits(0.22, (0.0, 0.12), (587.33, 587.33), SQUAREISH, 6, 0.07))
# Play video: one retro note that bends up a fifth and holds, like pressing play.
write("VideoPlayed", voice(0.3, lambda t: 392.0 * 1.5 ** min(1, t / 0.08), SQUAREISH,
                           lambda t: math.exp(-max(0.0, t - 0.1) * 10)))
# Music phrases acknowledge a hardware toggle, not a confirmed playing/paused state.
# A short mellow double tap and rising three-note pluck distinguish them from video cues.
write("MusicPause", hits(0.28, (0.0, 0.14), (261.63, 261.63), SPRING, 14, 0.12))
write("MusicPlay", hits(0.32, (0.0, 0.08, 0.16), (261.63, 329.63, 392.0), SPRING, 16, 0.14))
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

# A rising two-note bell acknowledges opening the active Voice conversation.
write("ShowVoice", hits(0.31, (0.035, 0.09, 0.205), (1746, 1556, 2093), WOOD, 43, 0.06))
write("SpotifyVolume", hits(0.28, (0.0, 0.06, 0.15), (660, 880, 1100), BUBBLE, 35, 0.08))
# Mac output volume has its own cue; no route, mute or live playback change. — GPT-6.1 Sol
write("YouTubeVolume", hits(0.25, (0.0, 0.085), (659.25, 1318.5), WOOD, 30, 0.1))
write("OutputVolume", hits(0.25, (0.0, 0.095), (784, 1174.66), WOOD, 30, 0.1))

write("Rewind", hits(0.37, (0.0, 0.085, 0.185), (1397, 932, 740), SQUAREISH, 40, 0.1))
write("RewindFive", hits(0.39, (0.0, 0.065, 0.23), (880, 698, 523), SQUAREISH, 38, 0.1))
write("RewindTen", hits(0.39, (0.0, 0.155, 0.21, 0.29), (1568, 1175, 880, 659), SQUAREISH, 38, 0.1))

# Dot calls are independent of the Codex Voice start/end chimes.
write("CallDot", hits(0.34, (0.02, 0.14, 0.25), (622, 830, 1046), SPRING, 28, 0.075))
write("HangUpDot", hits(0.31, (0.02, 0.15), (740, 370), WOOD, 35, 0.085))

# A quiet cue only after Reply is accepted; End reply and ordinary pauses have no cue. — GPT-6.1 Sol
write("NotificationReplyAccepted", hits(0.18, (0.0,), (1046.5,), SPRING, 35, 0.14), gain=0.35)

# A distinct ascending three-note cue after the requested chat speed is confirmed. — GPT-6.1 Sol
write("SetSpeed", hits(0.24, (0.0, 0.065, 0.13), (493.88, 739.99, 1108.73), WOOD, 28, 0.09))
write("CustomScript", hits(0.31, (0.0, 0.045, 0.17), (1568, 659.25, 1046.5), SPRING, 38, 0.095))

# Separate native output/navigation/media commands, generated without playing anything. — GPT-6.1 Sol
write("NextTrack", hits(0.24, (0.0, 0.065, 0.13), (523, 784, 1046), SPRING, 30, 0.08))
write("Back", hits(0.23, (0.0, 0.1), (1174.66, 784), WOOD, 35, 0.09))
write("Forward", hits(0.23, (0.0, 0.1), (784, 1174.66), WOOD, 35, 0.09))
