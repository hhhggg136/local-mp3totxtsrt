#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" -ne 2 ]]; then
    printf '用法：bash scripts/check-editor-memory.sh /绝对路径/授权测试素材 /绝对路径/对应字幕.srt\n' >&2
    exit 1
fi
mkdir -p .local/bin
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/SubtitleTranslation.swift launcher/LearningStore.swift launcher/workbench/EditorTimeline.swift launcher/workbench/SpeakerTypes.swift launcher/workbench/EditorMedia.swift launcher/workbench/AudioWorkbenchModel.swift launcher/workbench/SpeakerAnalysis.swift launcher/tests/EditorMemory.swift -o .local/bin/editor-memory
.local/bin/editor-memory --make-long-fixture .local/editor-memory-fixture
.local/bin/editor-memory "$1" "$2" .local/editor-memory-real > .local/editor-memory-real.log
.local/bin/editor-memory "$PWD/.local/editor-memory-fixture/synthetic-61min.wav" "$PWD/.local/editor-memory-fixture/synthetic-61min.srt" .local/editor-memory-long > .local/editor-memory-long.log
python3 - <<'PY'
from pathlib import Path
import json
for folder in ['.local/editor-memory-real','.local/editor-memory-long']:
    report=json.loads((Path(folder)/'memory.json').read_text())
    print(f"{report['durationSeconds']:.2f} seconds; {report['clips']} clips; peak RSS {report['processMaxRSSBytes']/1048576:.1f} MiB; sampled footprint {report['peakSampledPhysicalFootprintBytes']/1048576:.1f} MiB")
PY
