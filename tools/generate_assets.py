#!/usr/bin/env python3
"""Generate original short notification tones without recording or playing audio."""
import math
from pathlib import Path
import struct
import wave

TONES = {
    'enter_voice': (440, 660), 'exit_voice': (660, 440),
    'microphone_mute': (520, 390), 'cancel_microphone_mute': (390, 520),
    'headset_mute': (440, 330), 'cancel_headset_mute': (330, 440),
    'person_enter_voice': (550, 660), 'person_exit_voice': (550, 440),
}

def main():
    folder = Path(__file__).resolve().parents[1] / 'Resources/sounds'
    folder.mkdir(parents=True, exist_ok=True)
    rate, duration = 24000, 0.11
    for name, notes in TONES.items():
        data = bytearray()
        for freq in notes:
            count = int(rate * duration)
            for i in range(count):
                envelope = math.sin(math.pi * i / (count - 1)) ** 2
                value = 0.12 * envelope * math.sin(2 * math.pi * freq * i / rate)
                data.extend(struct.pack('<h', round(value * 32767)))
        with wave.open(str(folder / (name + '.wav')), 'wb') as out:
            out.setnchannels(1); out.setsampwidth(2); out.setframerate(rate); out.writeframes(data)

if __name__ == '__main__': main()
