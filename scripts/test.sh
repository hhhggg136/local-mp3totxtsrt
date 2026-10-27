#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bin
xcrun swiftc -swift-version 5 -parse-as-library launcher/LearningStore.swift launcher/tests/LearningTests.swift -o .local/bin/learning-tests
.local/bin/learning-tests

xcrun clang++ -std=c++17 launcher/tests/TimingTests.cpp -o .local/bin/timing-tests
.local/bin/timing-tests

xcrun swiftc -swift-version 5 -parse-as-library launcher/SubtitleTranslation.swift launcher/tests/TranslationTests.swift -o .local/bin/translation-tests
.local/bin/translation-tests

xcrun swiftc -swift-version 5 -parse-as-library launcher/SubtitleTranslation.swift launcher/workbench/EditorTimeline.swift launcher/tests/EditorTimelineTests.swift -o .local/bin/editor-core-tests
.local/bin/editor-core-tests

bash scripts/test-editor-audio.sh
