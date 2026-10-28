"""Build native Windows helpers and acquire explicitly pinned offline runtimes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT=Path(__file__).resolve().parents[1]
FFMPEG_URL='https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-27-18-38/ffmpeg-n9.0.2-36-g6882969ce9-win64-lgpl-shared-9.0.zip'
FFMPEG_SHA='f70e43c4f5670fbbf2dc4eb667b0d6b3743d68386f766c08bb2e0ec3edece398'
WHISPER_COMMIT='d1be6fde11ac6e0407606b4e42fe72d34add8037'
SPEAKER_SHA={'x64':'21da6a8b92d63ca02ad41dbfc120012343aaaec2e5e02b14819c6b4f38004509','arm64':'b3099bec60e6c3958275e90d0803d837cfe3ad6ed08528f29505d713b3a3e1bb'}
MODEL_INFO={
 'ggml-small.bin':('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin','1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b'),
 'ggml-silero-v6.2.0.bin':('https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin','2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987'),
 'campplus-zh-en.onnx':('https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx','aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2')}

def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as stream:
  for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
 return h.hexdigest()

def download(url,path,expected=None):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 if path.exists() and expected and sha(path)==expected:return path
 error=None
 for _ in range(3):
  temp=path.with_name(path.name+'.'+next(tempfile._get_candidate_names())+'.part')
  try:
   request=urllib.request.Request(url,headers={'User-Agent':'TingTingBeast-build/0.7'})
   with urllib.request.urlopen(request,timeout=90) as response,temp.open('xb') as output:
    shutil.copyfileobj(response,output,1024*1024)
   if expected and sha(temp)!=expected:raise ValueError('SHA-256 mismatch: '+path.name)
   os.replace(temp,path);return path
  except Exception as exc:error=exc
  finally:temp.unlink(missing_ok=True)
 raise RuntimeError('Download failed: '+url) from error

def extract_tar(file,destination):
 destination.mkdir(parents=True,exist_ok=True)
 with tarfile.open(file) as archive:archive.extractall(destination,filter='data')

def build(arch):
 stage=ROOT/'.local'/('win-'+arch);downloads=ROOT/'.local/windows-downloads';runtime=stage/'runtime'
 runtime.mkdir(parents=True,exist_ok=True)
 for name,(url,digest) in MODEL_INFO.items():
  target=download(url,downloads/name,digest);(runtime/'models').mkdir(exist_ok=True);shutil.copy2(target,runtime/'models'/name)
 ffmpeg=download(FFMPEG_URL,downloads/'ffmpeg-lgpl-9.0.zip',FFMPEG_SHA)
 with zipfile.ZipFile(ffmpeg) as z:
  for item in z.infolist():
   p=Path(item.filename)
   if item.is_dir():continue
   if p.parent.name=='bin' and (p.suffix.lower()=='.dll' or p.name in ['ffmpeg.exe','ffprobe.exe']):
    target=runtime/'ffmpeg'/p.name;target.parent.mkdir(exist_ok=True);target.write_bytes(z.read(item))
   elif p.name.lower() in ['license.txt','copying.lgplv2.1','copying.lgplv3','readme.txt']:
    target=runtime/'licenses'/('FFmpeg-'+p.name);target.parent.mkdir(exist_ok=True);target.write_bytes(z.read(item))
 sdk_url=f'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-win-{arch}-shared-MT-Release-no-tts-lib.tar.bz2'
 sdk=stage/'sherpa';extract_tar(download(sdk_url,downloads/('sherpa-'+arch+'.tar.bz2'),SPEAKER_SHA[arch]),sdk)
 include=sdk/'include/sherpa-onnx/c-api';include.mkdir(parents=True,exist_ok=True)
 download('https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/sherpa-onnx/c-api/c-api.h',include/'c-api.h','5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f')
 implib=next(sdk.rglob('sherpa-onnx-c-api.lib'));dll=next(sdk.rglob('sherpa-onnx-c-api.dll'))
 source=stage/'source'
 if not list(source.glob('*/CMakeLists.txt')):
  extract_tar(download(f'https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/{WHISPER_COMMIT}',downloads/'whisper-source.tar.gz'),source)
 whisper=next(p.parent for p in source.glob('*/CMakeLists.txt'))
 output=stage/'native-build'
 args=['cmake','-S',str(ROOT/'windows/native'),'-B',str(output),'-A','ARM64' if arch=='arm64' else 'x64',f'-DWHISPER_SOURCE={whisper}',f'-DSHERPA_INCLUDE={sdk/"include"}',f'-DSHERPA_IMPLIB={implib}',f'-DSHERPA_DLL={dll}']
 subprocess.run(args,check=True);subprocess.run(['cmake','--build',str(output),'--config','Release','--parallel','4'],check=True)
 for name in ['asr','speaker']:(runtime/name).mkdir(exist_ok=True)
 shutil.copy2(next(output.rglob('source-timed-whisper.exe')),runtime/'asr/source-timed-whisper.exe')
 shutil.copy2(next(output.rglob('speaker-embeddings.exe')),runtime/'speaker/speaker-embeddings.exe')
 for path in output.rglob('*.dll'):
  if 'Release' in path.parts:shutil.copy2(path,runtime/'asr'/path.name)
 for path in sdk.rglob('*.dll'):shutil.copy2(path,runtime/'speaker'/path.name)
 # Bundle app-local MSVC CRTs as well; tests must not rely on a development PC's
 # global redistributable. No administrator-level runtime installer is launched.
 vswhere=Path(os.environ.get('ProgramFiles(x86)','C:/Program Files (x86)'))/'Microsoft Visual Studio/Installer/vswhere.exe'
 if vswhere.exists():
  vs=Path(subprocess.check_output([str(vswhere),'-latest','-property','installationPath'],text=True).strip())
  directories=sorted((vs/'VC/Redist/MSVC').glob('*/'+arch+'/Microsoft.VC*.CRT'))
  if directories:
   for dllfile in directories[-1].glob('*.dll'):
    for name in ['asr','speaker']:shutil.copy2(dllfile,runtime/name/dllfile.name)
 licenses=runtime/'licenses';licenses.mkdir(exist_ok=True)
 for path in (ROOT/'launcher/licenses').iterdir():
  if path.is_file():shutil.copy2(path,licenses/path.name)
 shutil.copy2(ROOT/'LICENSE',licenses/'TingTingBeast-MIT.txt')
 (licenses/'Sources.txt').write_text(f'Whisper source: https://github.com/ggml-org/whisper.cpp/tree/{WHISPER_COMMIT}\nSherpa source: https://github.com/k2-fsa/sherpa-onnx/tree/v2.0.1\nFFmpeg LGPL build: {FFMPEG_URL}\nFFmpeg build scripts and source revisions: https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-10-27-18-38\nThe FFmpeg shared libraries are separate programs, replaceable in runtime/ffmpeg. No system changes or GPU runtime are required.\n',encoding='utf-8')
 manifest={'version':'0.7.0','architecture':arch,'whisperCommit':WHISPER_COMMIT,'speakerEngine':'2.0.1','modelsSHA256':{n:d for n,(_,d) in MODEL_INFO.items()},'ffmpegSHA256':FFMPEG_SHA}
 (runtime/'runtime.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
 print('RUNTIME='+str(runtime))
 return runtime

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--arch',choices=['x64','arm64'],required=True);args=parser.parse_args();build(args.arch)
