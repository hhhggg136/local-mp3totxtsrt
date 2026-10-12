"""Real-engine regression: two authorized speech excerpts separated by digital silence.
No media is bundled or uploaded. Supply a decoded 16kHz mono PCM16 WAV and two speech ranges.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
import wave

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--audio", type=Path, required=True)
parser.add_argument("--lead-in", type=float, default=2, help="seconds of digital silence before first excerpt")
parser.add_argument("--clips", nargs=2, required=True, help="two start:end ranges in seconds")
parser.add_argument("--artifact-root", type=Path, default=Path(".local/timing-regression"))
args = parser.parse_args()
folder = (args.artifact_root / uuid.uuid4().hex).resolve()
folder.mkdir(parents=True)
with wave.open(str(args.audio), "rb") as source:
    assert (source.getframerate(), source.getnchannels(), source.getsampwidth()) == (16000, 1, 2)
    clips = []
    for value in args.clips:
        start, end = map(float, value.split(":"))
        assert 0 <= start < end <= source.getnframes() / 16000
        source.setpos(round(start * 16000))
        clips.append(source.readframes(round((end - start) * 16000)))
assert args.lead_in >= 0
first_end = args.lead_in + len(clips[0]) / 32000
second_start = first_end + 4
with wave.open(str(folder / "fixture.wav"), "wb") as output:
    output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    output.writeframes(bytes(round(32000 * args.lead_in)) + clips[0] + bytes(32000 * 4) + clips[1] + bytes(32000 * 2))
environment = dict(os.environ, LOCAL_SUBTITLE_DATA_DIR=str(folder / "isolated-library"))
subprocess.run([str(args.app.resolve() / "Contents/MacOS/SubtitleLauncher"), "--self-test", str(folder / "fixture.wav"), str(folder)], env=environment, check=True)
result = next(folder.glob("字幕_*"))
srt = (result / "字幕.srt").read_text(encoding="utf-8")
def seconds(value):
    h, m, s, ms = map(int, re.split("[:,]", value))
    return h * 3600 + m * 60 + s + ms / 1000
intervals = []
for index, block in enumerate(srt.strip().split("\n\n"), 1):
    lines = block.splitlines()
    assert int(lines[0]) == index
    start, end = map(seconds, lines[1].split(" --> "))
    assert 0 <= start < end
    silent_overlap = max(0, min(end, second_start - 0.06) - max(start, first_end + 0.06))
    assert silent_overlap <= 0.01, f"字幕跨越已知静音：{start}–{end}"
    intervals.append((start, end))
assert any(end <= first_end + 0.1 for start, end in intervals), "第一段对白缺失"
assert any(start >= second_start - 0.1 for start, end in intervals), "第二段对白缺失"
assert (result / "字幕.srt").read_bytes() == (result / "学习基准.srt").read_bytes()
print(json.dumps({"passed": True, "known_silence": [first_end, second_start], "subtitle_intervals": intervals, "artifacts": str(folder)}, ensure_ascii=False, indent=2))
