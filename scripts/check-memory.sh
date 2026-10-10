#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bin
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/LearningStore.swift launcher/tests/LearningMemory.swift -o .local/bin/learning-memory
/usr/bin/time -l .local/bin/learning-memory --baseline > .local/learning-memory-baseline.txt 2> .local/learning-memory-baseline-time.txt
/usr/bin/time -l .local/bin/learning-memory > .local/learning-memory-result.json 2> .local/learning-memory-time.txt
cat .local/learning-memory-result.json
