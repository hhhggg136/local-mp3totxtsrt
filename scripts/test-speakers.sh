#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" -ne 2 ]]; then
    printf '用法：bash scripts/test-speakers.sh /绝对路径/授权素材 /绝对路径/对应字幕.srt\n' >&2
    exit 1
fi
mkdir -p .local/bin
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/SubtitleTranslation.swift launcher/LearningStore.swift launcher/workbench/EditorTimeline.swift launcher/workbench/SpeakerTypes.swift launcher/workbench/EditorMedia.swift launcher/workbench/SpeakerAnalysis.swift launcher/tests/SpeakerIntegration.swift -o .local/bin/speaker-integration
output=$(mktemp -d "$PWD/.local/speaker-check.XXXXXX")
.local/bin/speaker-integration "$1" "$2" "$PWD" "$output"
