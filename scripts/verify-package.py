#!/usr/bin/env python3
"""Mount a DMG, relocate the app and verify it cannot depend on the source checkout.
Usage: python3 scripts/verify-package.py package.json /path/to/authorized-media
"""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
manifest = json.loads(Path(sys.argv[1]).read_text())
source = Path(sys.argv[2]).resolve()
def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()
def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)
original_hash = sha(source)
dmg = Path(manifest['dmg'])
run('hdiutil', 'verify', dmg)
mount = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(dmg)]))
volume = next(Path(item['mount-point']) for item in mount['system-entities'] if 'mount-point' in item)
temporary = Path(tempfile.mkdtemp(prefix='TingTingBeast-package-check-'))
app = temporary / '本地字幕工具.app'
try:
    run('ditto', '--norsrc', '--noextattr', volume / app.name, app)
finally:
    run('hdiutil', 'detach', volume)
run('codesign', '--verify', '--deep', '--strict', app)
assert sha(app / 'Contents/Resources/AppIcon.icns') == sha(root / '本地字幕工具.app/Contents/Resources/AppIcon.icns')
runtime = app / 'Contents/Resources/Runtime'
configuration = json.loads((runtime / 'runtime.json').read_text())
for name, digest in configuration['models_sha256'].items():
    assert sha(runtime / '.local/models' / name) == digest, name
binaries = [app / 'Contents/MacOS/SubtitleLauncher', *(runtime / '.local/bin').iterdir()]
binaries += [p for p in (runtime / '.local/whisper-engine/build/bin').glob('*.dylib') if not p.is_symlink()]
for binary in binaries:
    info = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    assert str(root) not in info, binary
    assert '/Users/' not in subprocess.check_output(['otool', '-l', str(binary)], text=True), binary
    assert 'arm64' in subprocess.check_output(['lipo', '-archs', str(binary)], text=True), binary
# Disallow reading the entire development checkout, not just a handpicked helper.
# A successful real recognition run therefore proves use of bundled dependencies.
profile = temporary / 'deny-checkout.sb'
profile.write_text('(version 1)\n(allow default)\n(deny file-read* (subpath ' + json.dumps(str(root), ensure_ascii=False) + '))\n')
environment = dict(os.environ)
environment.pop('LOCAL_SUBTITLE_ROOT', None)
environment['LOCAL_SUBTITLE_DATA_DIR'] = str(temporary / 'isolated-library')
with (temporary / 'run.stdout').open('w') as out, (temporary / 'run.stderr').open('w') as error:
    run('/usr/bin/sandbox-exec', '-f', profile, app / 'Contents/MacOS/SubtitleLauncher', '--self-test', source, temporary / 'results', env=environment, cwd=temporary, stdout=out, stderr=error)
folder = next((temporary / 'results').glob('字幕_*'))
metadata = json.loads((folder / '本次词库.json').read_text())
assert metadata['version'] == configuration['version']
raw = json.loads((folder / '识别原始结果.json').read_bytes().decode('utf-8', 'replace'))
regions = {(r['from'], r['to']) for r in raw['speech_regions']}
for row in raw['transcription']:
    assert (row['offsets']['from'], row['offsets']['to']) in regions
    assert 0 <= row['offsets']['from'] < row['offsets']['to'] <= raw['duration_ms']
srt = (folder / '字幕.srt').read_text()
assert len(srt.strip().split('\n\n')) == len(raw['transcription']) > 0
assert (folder / '学习基准.srt').read_bytes() == (folder / '字幕.srt').read_bytes()
assert sha(source) == original_hash
report = {'passed': True, 'version': configuration['version'], 'architecture': 'arm64',
          'minimum_macos': configuration['minimum_macos'], 'dmg_sha256': sha(dmg),
          'source_checkout_denied': True, 'bundled_models_verified': True,
          'icon_matches_mascot_build': True, 'subtitle_count': len(raw['transcription']),
          'original_media_unchanged': True,
          'translation_language_pack_download': 'not verified',
          'gatekeeper_on_other_mac': 'not verified; ad-hoc signature, not notarized'}
report_path = dmg.parent / 'verification.json'
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
print('Local-only diagnostic artifacts:', temporary)
