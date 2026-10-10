#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bin .local/build
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/AudioDecoder.swift -o .local/bin/inspect
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/SubtitleLauncher.swift launcher/LearningStore.swift launcher/LearningPanel.swift -o .local/build/SubtitleLauncher
app='本地字幕工具.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .local/build/SubtitleLauncher "$app/Contents/MacOS/SubtitleLauncher"
cp launcher/Info.plist "$app/Contents/Info.plist"
xcrun swift launcher/MakeIcon.swift .local/Subtitle.iconset
iconutil -c icns .local/Subtitle.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
printf '已构建：%s/%s\n' "$PWD" "$app"
