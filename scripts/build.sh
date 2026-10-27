#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/bin .local/build
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/AudioDecoder.swift -o .local/bin/inspect
xcrun swiftc -O -swift-version 5 -parse-as-library launcher/SubtitleLauncher.swift launcher/LearningStore.swift launcher/LearningPanel.swift launcher/SubtitleTranslation.swift launcher/TranslationControls.swift launcher/workbench/*.swift -o .local/build/SubtitleLauncher
engine=.local/whisper-engine
if [[ -f "$engine/build/bin/libwhisper.dylib" ]]; then
    xcrun clang++ -O2 -std=c++17 launcher/native/SourceTimedWhisper.cpp -I "$engine/include" -I "$engine/ggml/include" -L "$engine/build/bin" -lwhisper '-Wl,-rpath,@executable_path/../whisper-engine/build/bin' -o .local/bin/source-timed-whisper
else
    printf '尚未配置 whisper.cpp；窗口可以构建，识别前请运行 setup-local.sh --download。\n' >&2
fi
app='本地字幕工具.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .local/build/SubtitleLauncher "$app/Contents/MacOS/SubtitleLauncher"
cp launcher/Info.plist "$app/Contents/Info.plist"
xcrun swift launcher/MakeIcon.swift .local/Subtitle.iconset
iconutil -c icns .local/Subtitle.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
printf '已构建：%s/%s\n' "$PWD" "$app"
