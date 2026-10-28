#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bin
sources=(launcher/SubtitleTranslation.swift launcher/LearningStore.swift launcher/workbench/EditorTimeline.swift launcher/workbench/SpeakerTypes.swift launcher/workbench/EditorMedia.swift launcher/workbench/AudioWorkbenchModel.swift launcher/workbench/SpeakerAnalysis.swift)
xcrun swiftc -O -swift-version 5 -parse-as-library "${sources[@]}" launcher/tests/EditorAudioIntegration.swift -o .local/bin/editor-audio-integration
.local/bin/editor-audio-integration | tee .local/editor-audio-integration.log
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/AudioDecoder.swift -o .local/bin/inspect
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/SubtitleTranslation.swift launcher/workbench/EditorTimeline.swift launcher/workbench/SpeakerTypes.swift launcher/workbench/EditorMedia.swift launcher/tests/EditorOffsetIntegration.swift -o .local/bin/editor-offset-integration
fixture=$(python3 -c 'from pathlib import Path; print(Path(Path(".local/editor-audio-integration.log").read_text().split("REPORT=")[-1].strip()).parent / "three-tones.wav")')
.local/bin/editor-offset-integration "$fixture" "$PWD/.local/bin/inspect" | tee .local/editor-offset-integration.log
