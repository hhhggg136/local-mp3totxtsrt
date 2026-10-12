#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bin
xcrun swiftc -swift-version 5 -parse-as-library launcher/LearningStore.swift launcher/tests/LearningTests.swift -o .local/bin/learning-tests
.local/bin/learning-tests

xcrun clang++ -std=c++17 launcher/tests/TimingTests.cpp -o .local/bin/timing-tests
.local/bin/timing-tests
