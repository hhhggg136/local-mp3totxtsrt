#!/usr/bin/env python3
"""Package the local macOS app with an explicitly allowlisted offline runtime."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
def run(*args):
    subprocess.run([str(a) for a in args], check=True)
def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

source = ROOT / '本地字幕工具.app'
with (source / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
version = info['CFBundleShortVersionString']
if subprocess.check_output(['uname', '-m'], text=True).strip() != 'arm64':
    raise SystemExit('This packaging script currently targets Apple silicon only.')
run('codesign', '--verify', '--deep', '--strict', source)
models = {
    'ggml-small.bin': '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
    'ggml-silero-v6.2.0.bin': '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
}
for name, expected in models.items():
    if sha(ROOT / '.local/models' / name) != expected:
        raise SystemExit(f'Model SHA-256 mismatch: {name}')
output = ROOT / '.local/distributions' / (version + '-' + uuid.uuid4().hex[:8])
stage = output / 'image'
stage.mkdir(parents=True)
app = stage / source.name
# Do not copy an entire development directory or an existing runtime.
(app / 'Contents/MacOS').mkdir(parents=True)
resources = app / 'Contents/Resources'
resources.mkdir()
shutil.copy2(source / 'Contents/MacOS/SubtitleLauncher', app / 'Contents/MacOS/SubtitleLauncher')
shutil.copy2(source / 'Contents/Resources/AppIcon.icns', resources / 'AppIcon.icns')
info['LSMinimumSystemVersion'] = '26.0'
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
runtime = resources / 'Runtime'
bin_dir = runtime / '.local/bin'
model_dir = runtime / '.local/models'
lib_dir = runtime / '.local/whisper-engine/build/bin'
for directory in (bin_dir, model_dir, lib_dir):
    directory.mkdir(parents=True)
for name in ('inspect', 'source-timed-whisper'):
    shutil.copy2(ROOT / '.local/bin' / name, bin_dir / name)
for name in models:
    shutil.copy2(ROOT / '.local/models' / name, model_dir / name)
engine_libs = ROOT / '.local/whisper-engine/build/bin'
for file in engine_libs.glob('lib*.dylib'):
    if file.is_symlink():
        target = os.readlink(file)
        if Path(target).is_absolute() or '/' in target:
            raise SystemExit(f'Unexpected external library symlink: {file.name}')
        (lib_dir / file.name).symlink_to(target)
    else:
        shutil.copy2(file, lib_dir / file.name)
# Remove build-machine lookup paths; every library resolves from its own directory.
for library in sorted(lib_dir.glob('*.dylib')):
    if library.is_symlink():
        continue
    lines = subprocess.check_output(['otool', '-l', str(library)], text=True).splitlines()
    paths = []
    for index, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            paths.append(lines[index + 2].strip().split('path ', 1)[1].rsplit(' (offset', 1)[0])
    for path in paths:
        run('install_name_tool', '-delete_rpath', path, library)
    run('install_name_tool', '-add_rpath', '@loader_path', library)
    run('codesign', '--force', '--sign', '-', library)
for name in ('inspect', 'source-timed-whisper'):
    run('codesign', '--force', '--sign', '-', bin_dir / name)
manifest = {
    'version': version, 'architecture': 'arm64', 'minimum_macos': '26.0',
    'engine': 'whisper.cpp v1.9.5',
    'engine_commit': 'd1be6fde11ac6e0407606b4e42fe72d34add8037',
    'models_sha256': models,
    'speech_alignment': 'source-vad-islands-v1',
    'translation': 'Apple Translation; language packs downloaded through system UI on first use',
}
(runtime / 'runtime.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
licenses = resources / 'ThirdPartyLicenses'
shutil.copytree(ROOT / 'launcher/licenses', licenses)
shutil.copy2(ROOT / 'LICENSE', licenses / 'LocalSubtitleTool-LICENSE.txt')
for license_file in licenses.iterdir():
    if license_file.stat().st_size < 500:
        raise SystemExit(f'Missing license content: {license_file.name}')
run('codesign', '--force', '--sign', '-', app)
run('codesign', '--verify', '--deep', '--strict', app)
(stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
(stage / '安装与使用说明.txt').write_text(f'''听听兽 · 本地字幕工具 {version}

适用：Apple 芯片 Mac（M1 / M2 / M3 / M4 / M5 等），macOS 26 或更新版本。
不适用于 Intel Mac、Windows 或 macOS 25 及更早版本。

安装：把「本地字幕工具」拖到「Applications」文件夹，再从应用程序打开。
识别模型及引擎已包含，不需要开发环境、命令行工具或另行配置模型。
模型约 488.5 MB；请预留约 2 GB 空间用于安装、下载文件和临时音频。

首次打开：此版本为本地临时签名，未取得 Apple Developer ID 签名和公证。
macOS 可能阻止首次启动。确认下载来自项目 GitHub 后，可到「系统设置 → 隐私与安全性」允许打开。
无需关闭 Gatekeeper、关闭 SIP 或运行终端安全绕过命令。
如果系统无法按正常方式允许打开，请停止并反馈，不建议关闭系统保护。

功能：中文、英语、西班牙语及自动识别，输出原文 TXT / SRT，保留停顿；按项目管理校对词库。
翻译：选择原文、译文语言，点击「一键翻译」。勾选「双语字幕」可额外输出原文在上、译文在下的 SRT。
首次翻译可能需要由系统下载语言包；当前语言包下载及真实翻译仍待完整验证。
音频剪辑、波形和对白重排尚未开放。识别文字、时间边界与译文均需要人工核对。

隐私：不包含任何个人音视频、字幕、测试输出或学习记录。
音视频和学习在本地处理。语言包下载由 macOS 系统提供，无需云端 API Key。
个人词库保存在用户资源库 Application Support/LocalSubtitleTool，与应用升级分开。

代码及更新：https://github.com/hhhggg136/local-mp3totxtsrt
开源许可：应用包 Contents/Resources/ThirdPartyLicenses。
''', encoding='utf-8')
dmg = output / f'TingTingBeast-{version}-macOS26-AppleSilicon.dmg'
run('hdiutil', 'create', '-srcfolder', stage, '-volname', '听听兽字幕工具', '-format', 'UDZO', '-imagekey', 'zlib-level=6', dmg)
checksum = output / 'SHA256SUMS.txt'
checksum.write_text(sha(dmg) + '  ' + dmg.name + '\n', encoding='ascii')
(output / 'package.json').write_text(json.dumps({'dmg': str(dmg), 'checksum': str(checksum), 'stage_app': str(app)}, ensure_ascii=False, indent=2), encoding='utf-8')
print('PACKAGE=' + str(output / 'package.json'))
