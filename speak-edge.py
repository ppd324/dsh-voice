"""Neural TTS via edge-tts (free Microsoft voices), played through the system mixer.

usage: speak-edge.py <text> [voice] [rate]
  voice  e.g. zh-CN-XiaoxiaoNeural, zh-CN-YunxiNeural, zh-CN-XiaoyiNeural
  rate   e.g. +0%, +10%, -10%

Falls back to exiting non-zero so the caller can use SAPI instead.
"""
import asyncio
import json
import os
import subprocess
import sys
import tempfile

import edge_tts

def _find_ffmpeg() -> str:
    """Locate ffmpeg: env override, then config.json next to this script, then PATH."""
    env = os.environ.get("DSH_VOICE_FFMPEG")
    if env and os.path.isfile(env):
        return env
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "config.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
        cand = cfg.get("ffmpeg")
        if cand and os.path.isfile(cand):
            return cand
    except Exception:
        pass
    return "ffmpeg"


FFMPEG = _find_ffmpeg()
PWSH = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

PS_PLAY = (
    "$p = New-Object System.Media.SoundPlayer '{wav}';"
    "$p.PlaySync()"
)


def cache_only(args) -> int:
    """--cache <text> <voice> <rate> <out.wav>: synthesize to a wav without playing."""
    text, voice, rate, out = args[0], args[1], args[2], args[3]
    mp3 = out + ".mp3"

    async def synth():
        await edge_tts.Communicate(text, voice, rate=rate).save(mp3)

    try:
        asyncio.run(synth())
        conv = subprocess.run(
            [FFMPEG, "-y", "-loglevel", "error", "-i", mp3, "-ar", "24000", "-ac", "1", out],
            capture_output=True,
        )
        return 0 if conv.returncode == 0 else 5
    except Exception as exc:
        print(f"cache failed: {exc}", file=sys.stderr)
        return 3
    finally:
        try:
            os.remove(mp3)
        except OSError:
            pass


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--cache":
        return cache_only(sys.argv[2:])
    if len(sys.argv) < 2:
        print("usage: speak-edge.py <text> [voice] [rate]", file=sys.stderr)
        return 2
    text = sys.argv[1]
    voice = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "zh-CN-XiaoxiaoNeural"
    rate = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "+0%"

    base = os.path.join(tempfile.gettempdir(), f"dsh-tts-{os.getpid()}")
    mp3 = base + ".mp3"
    wav = base + ".wav"

    try:
        async def synth():
            communicate = edge_tts.Communicate(text, voice, rate=rate)
            await communicate.save(mp3)

        try:
            asyncio.run(synth())
        except Exception as exc:  # network / voice errors -> caller falls back
            print(f"edge-tts failed: {exc}", file=sys.stderr)
            return 3

        if not os.path.exists(mp3) or os.path.getsize(mp3) == 0:
            return 4

        conv = subprocess.run(
            [FFMPEG, "-y", "-loglevel", "error", "-i", mp3, "-ar", "24000", "-ac", "1", wav],
            capture_output=True,
        )
        if conv.returncode != 0:
            print(conv.stderr.decode("utf-8", "replace")[:400], file=sys.stderr)
            return 5

        subprocess.run([PWSH, "-NoProfile", "-Command", PS_PLAY.format(wav=wav)], check=False)
        return 0
    finally:
        for f in (mp3, wav):
            try:
                os.remove(f)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
