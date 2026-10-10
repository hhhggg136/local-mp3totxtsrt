#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cat <<'INFO'
将获取 whisper.cpp v1.9.5 源码，并在本项目 .local 内编译。
模型来源：huggingface.co/ggerganov/whisper.cpp（small，487601967 字节）
人声检测来源：huggingface.co/ggml-org/whisper-vad（885098 字节）
模型保存在 .local/models；不会上传任何音视频。
需要已安装 Xcode Command Line Tools、Git、CMake、curl。
INFO
if [[ "${1:-}" != "--download" ]]; then
    printf '\n确认以上下载范围后，运行：bash scripts/setup-local.sh --download\n'
    exit 0
fi
for tool in git cmake curl shasum xcrun; do
    command -v "$tool" >/dev/null || { printf '缺少工具：%s\n' "$tool" >&2; exit 1; }
done
mkdir -p .local/models
if [[ ! -d .local/whisper-engine ]]; then
    git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git .local/whisper-engine
fi
expected=d1be6fde11ac6e0407606b4e42fe72d34add8037
actual=$(git -C .local/whisper-engine rev-parse HEAD)
[[ "$actual" == "$expected" ]] || { printf '引擎版本不匹配，保留现有目录，请人工检查。\n' >&2; exit 1; }
cmake -S .local/whisper-engine -B .local/whisper-engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build .local/whisper-engine/build --config Release -j 4 --target whisper-cli
fetch() {
    local url="$1" destination="$2" hash="$3"
    if [[ -f "$destination" ]] && printf '%s  %s\n' "$hash" "$destination" | shasum -a 256 -c - >/dev/null 2>&1; then
        printf '已验证本地模型：%s\n' "$destination"
        return
    fi
    if [[ -e "$destination" ]]; then
        printf '已有模型校验不通过，未覆盖：%s\n' "$destination" >&2
        exit 1
    fi
    curl --fail --location --retry 3 "$url" -o "$destination.partial"
    printf '%s  %s\n' "$hash" "$destination.partial" | shasum -a 256 -c -
    mv "$destination.partial" "$destination"
}
fetch 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin' .local/models/ggml-small.bin 1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b
fetch 'https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin' .local/models/ggml-silero-v6.2.0.bin 2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987
bash scripts/build.sh
