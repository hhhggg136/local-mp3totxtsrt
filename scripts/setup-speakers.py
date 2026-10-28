#!/usr/bin/env python3
"""Optional native speaker runtime. Print sources first; --download installs it."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2'
MODEL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx'
HEADER = 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/sherpa-onnx/c-api/c-api.h'
ARCHIVE_SHA = 'ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3'
MODEL_SHA = 'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2'
HEADER_SHA = '5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--download', action='store_true')
args = parser.parse_args()
destination = ROOT / '.local/speaker-runtime'
print('说话人模型 28,281,164 字节；运行库压缩包 8,455,084 字节；另有编译头文件。')
print('保存位置:', destination)
print('模型:', MODEL, '\n引擎:', ARCHIVE, '\n头文件:', HEADER)
if not args.download:
    print('仅显示配置；需要时加 --download 下载并校验，不会上传音频。')
    raise SystemExit(0)
if subprocess.check_output(['uname', '-m'], text=True).strip() != 'arm64':
    raise SystemExit('当前配置仅支持 Apple 芯片 Mac。')
if destination.exists():
    required = {'campplus-zh-en.onnx': MODEL_SHA, 'include/sherpa-onnx/c-api/c-api.h': HEADER_SHA}
    valid = all((destination / name).is_file() and hashlib.sha256((destination / name).read_bytes()).hexdigest() == digest for name, digest in required.items())
    valid = valid and all((destination / 'lib' / name).is_file() for name in ['libonnxruntime.dylib', 'libsherpa-onnx-c-api.dylib'])
    if valid:
        print('已有配置校验通过，未下载或覆盖。')
        raise SystemExit(0)
    raise SystemExit('目标目录已存在但不完整，保持原样；请先核对现有配置。')
destination.parent.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='speaker-install-', dir=destination.parent) as temporary:
    stage = Path(temporary)
    def get(url, name, expected):
        file = stage / name
        # A failed response is never reused as a later download or installed model.
        with urllib.request.urlopen(url, timeout=60) as response, file.open('xb') as output:
            shutil.copyfileobj(response, output, 1024 * 1024)
        h = hashlib.sha256()
        with file.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
        if h.hexdigest() != expected: raise SystemExit('SHA-256 校验失败: ' + name)
        return file
    archive = get(ARCHIVE, 'runtime.tar.bz2', ARCHIVE_SHA)
    model = get(MODEL, 'campplus-zh-en.onnx', MODEL_SHA)
    header = get(HEADER, 'c-api.h', HEADER_SHA)
    target = stage / 'runtime'; (target / 'lib').mkdir(parents=True)
    with tarfile.open(archive) as tar:
        for name in ['libonnxruntime.dylib', 'libsherpa-onnx-c-api.dylib']:
            members = [m for m in tar.getmembers() if m.name.endswith('/lib/' + name) and m.isfile()]
            if len(members) != 1: raise SystemExit('运行库清单不正确')
            with tar.extractfile(members[0]) as source, (target / 'lib' / name).open('xb') as output: shutil.copyfileobj(source, output)
            subprocess.run(['codesign', '--force', '--sign', '-', target / 'lib' / name], check=True)
    include = target / 'include/sherpa-onnx/c-api'; include.mkdir(parents=True)
    shutil.copy2(header, include / 'c-api.h'); shutil.copy2(model, target / model.name)
    (target / 'manifest.json').write_text(json.dumps({'version': 'sherpa-onnx v2.0.1', 'modelSHA256': MODEL_SHA, 'modelBytes': 28281164, 'modelLicense': 'Apache-2.0'}, indent=2))
    if destination.exists():
        # Never overwrite an installed or user-selected model during setup.
        raise SystemExit('目标目录已存在，保持原样。请先核对现有配置。')
    target.rename(destination)
print('配置完成；运行 bash scripts/build.sh 编译本地程序。')
