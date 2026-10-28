"""Real native inference on Windows, including a non-ASCII model/audio path."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import uuid
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tingting.core import Cue,Span
from tingting.speakers import group

def run_measured(args,cwd,timeout):
 import ctypes
 import struct
 process=subprocess.Popen([str(x) for x in args],cwd=cwd);peak=0;deadline=time.monotonic()+timeout
 ctypes.windll.psapi.GetProcessMemoryInfo.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32]
 try:
  while process.poll() is None:
   data=ctypes.create_string_buffer(80);ctypes.c_uint32.from_buffer(data).value=80
   if ctypes.windll.psapi.GetProcessMemoryInfo(int(process._handle),data,80):peak=max(peak,struct.unpack_from('<Q',data,8)[0])
   if time.monotonic()>deadline:raise TimeoutError('Native inference timed out')
   time.sleep(.05)
  if process.returncode:raise RuntimeError('Native inference failed: '+str(process.returncode))
 finally:
  if process.poll() is None:process.terminate();process.wait()
 return peak

runtime=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='听听兽 原生验证 ') as folder:
 root=Path(folder);model=root/'模型';model.mkdir()
 for name in ['ggml-small.bin','ggml-silero-v6.2.0.bin','campplus-zh-en.onnx']:shutil.copy2(runtime/'models'/name,model/name)
 file=root/'语音 sample.wav'
 url='https://raw.githubusercontent.com/csukuangfj/sr-data/92b4978ba6b4358e95be385e51e86ece86524d33/test/3d-speaker/speaker1_a_cn_16k.wav'
 with urllib.request.urlopen(url,timeout=60) as response,file.open('wb') as output:shutil.copyfileobj(response,output)
 result=root/'识别结果.json'
 command=[runtime/'asr/source-timed-whisper.exe',model/'ggml-small.bin',model/'ggml-silero-v6.2.0.bin',file,result,'','zh']
 asr_peak=run_measured(command,runtime/'asr',600);assert asr_peak>0
 data=json.loads(result.read_text(encoding='utf-8'));assert data['transcription']
 regions={(r['from'],r['to']) for r in data['speech_regions']}
 assert all((c['offsets']['from'],c['offsets']['to']) in regions for c in data['transcription'])
 import wave
 with wave.open(str(file),'rb') as w:frames=w.getnframes()
 id=str(uuid.uuid4()).upper();ranges=root/'区间.tsv';ranges.write_text(f'{id}\t0\t{frames*3}',encoding='utf-8')
 out=root/'vectors.bin';stats=root/'stats.json'
 subprocess.run([str(x) for x in [runtime/'speaker/speaker-embeddings.exe',model/'campplus-zh-en.onnx',file,ranges,out,stats]],check=True,timeout=120,cwd=runtime/'speaker')
 assert out.read_bytes().startswith(b'TTSPK001') and out.stat().st_size>8
 metrics=json.loads(stats.read_text());assert metrics['peakRSSBytes']>0
 report={'passed':True,'unicodeNativePaths':True,'realASRCues':len(data['transcription']),'vadTimesRetained':True,'realSpeakerEmbeddings':True,'speakerPeakWorkingSetBytes':metrics['peakRSSBytes'],'asrObservedPeakWorkingSetBytes':asr_peak,'asrMeasurementIntervalMilliseconds':50}
 target=runtime.parent/'native-verification.json';target.write_text(json.dumps(report,indent=2));print(json.dumps(report))
