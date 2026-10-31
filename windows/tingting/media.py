"""Bounded file/pipe media processing. No decoded recording is kept in RAM."""
from __future__ import annotations
import array
import copy
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from .core import Cancelled, UserError, Source, Project, SCALE, fingerprint, portable_path

VERSION='0.7.1'
MODEL_HASHES={'ggml-small.bin':'1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
 'ggml-silero-v6.2.0.bin':'2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
 'campplus-zh-en.onnx':'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2'}

def data_root():
    base=Path(os.environ.get('LOCAL_SUBTITLE_DATA_DIR') or (Path(os.environ.get('LOCALAPPDATA',Path.home()))/'LocalSubtitleTool'))
    base.mkdir(parents=True,exist_ok=True);return base

def app_root():
    if getattr(sys,'frozen',False):return Path(sys.executable).resolve().parent
    return Path(os.environ.get('TINGTING_WINDOWS_ROOT',Path(__file__).resolve().parents[2]/'.local/windows-app'))

class Runtime:
    def __init__(self,root=None,data=None):
        self.root=Path(root) if root else app_root()
        self.data=Path(data) if data else data_root();self.data.mkdir(parents=True,exist_ok=True)
        parent=self.data/'cache';parent.mkdir(exist_ok=True)
        self.cache=Path(tempfile.mkdtemp(prefix='session-',dir=parent))
        self.cancel=threading.Event();self.process=None;self.lock=threading.Lock();self.checked={}
    def binary(self,name):
        suffix='.exe' if os.name=='nt' else ''
        folder='ffmpeg' if name in ['ffmpeg','ffprobe'] else ('speaker' if name=='speaker-embeddings' else 'asr')
        file=self.root/'runtime'/folder/(name+suffix)
        if not file.is_file():raise UserError(f'缺少本地组件 {name}，请重新安装完整版本。')
        return file
    def model(self,name):
        file=self.root/'runtime/models'/name
        if not file.is_file():raise UserError('安装包缺少本地模型，请重新安装完整版本。')
        info=file.stat();identity=(info.st_size,info.st_mtime_ns)
        if self.checked.get(name)!=identity:
            if fingerprint(file,self.cancel)!=MODEL_HASHES[name]:raise UserError('本地模型校验失败，请重新安装。')
            self.checked[name]=identity
        return file
    def check(self):
        if self.cancel.is_set():raise Cancelled('任务已取消，当前编辑和原素材保留。')
    def start(self,args,stdin=None,stdout=None,stderr=None,env=None):
        self.check();args=[str(x) for x in args]
        child_env=os.environ.copy();child_env['PYTHONUTF8']='1'
        if env:child_env.update(env)
        flags=(subprocess.CREATE_NO_WINDOW|subprocess.BELOW_NORMAL_PRIORITY_CLASS) if os.name=='nt' else 0
        if os.name=='nt' and getattr(sys,'frozen',False):
            import ctypes
            ctypes.windll.kernel32.SetDllDirectoryW(None)
        try:
            process=subprocess.Popen(args,stdin=stdin,stdout=stdout,stderr=stderr,creationflags=flags,env=child_env,cwd=str(Path(args[0]).parent))
        finally:
            if os.name=='nt' and getattr(sys,'frozen',False):
                ctypes.windll.kernel32.SetDllDirectoryW(str(sys._MEIPASS))
        with self.lock:self.process=process
        return process
    def finish(self,process):
        try:
            while process.poll() is None:
                self.check();time.sleep(.05)
            self.check()
            if process.returncode:raise UserError('处理未完成，请检查素材格式、磁盘空间或重试。')
        finally:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            with self.lock:
                if self.process is process:self.process=None
    def run(self,args,log=None):
        log=Path(log) if log else self.cache/'last-task.log'
        with log.open('wb') as handle:
            process=self.start(args,stdout=handle,stderr=handle);self.finish(process)
    def capture(self,args,limit=2_000_000):
        # Capture via a bounded local file; a misbehaving helper cannot fill a pipe
        # while the parent waits for process termination.
        target=self.cache/('capture-'+uuid.uuid4().hex)
        try:
            self.run(args,log=target)
            if target.stat().st_size>limit:raise UserError('组件输出过大，已停止读取。')
            return target.read_bytes()
        finally:target.unlink(missing_ok=True)
    def request_cancel(self):self.cancel.set()
    def reset(self):self.cancel.clear()
    def close(self):
        self.cancel.set()
        with self.lock:process=self.process
        if process and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        shutil.rmtree(self.cache,ignore_errors=True)

class Media:
    def __init__(self,runtime):self.runtime=runtime;self.preview=None;self.preview_hash=None
    def inspect(self,path):
        path=Path(path).resolve()
        if not path.is_file():raise UserError('素材不存在或无法读取。')
        before=path.stat()
        payload=self.runtime.capture([self.runtime.binary('ffprobe'),'-v','error','-show_format','-show_streams','-of','json',path])
        info=json.loads(payload.decode('utf-8','replace'))
        if not any(s.get('codec_type')=='audio' for s in info.get('streams',[])):raise UserError('所选素材没有音轨。')
        duration=info.get('format',{}).get('duration')
        if not duration:duration=next((s.get('duration') for s in info.get('streams',[]) if s.get('codec_type')=='audio' and s.get('duration')),None)
        try:ticks=int((Decimal(duration)*SCALE).to_integral_value(rounding=ROUND_HALF_UP))
        except Exception as exc:raise UserError('无法读取素材总时长，请先转换为常见 MP4/WAV 格式。') from exc
        if not 0<ticks<=24*3600*SCALE:raise UserError('当前版本支持 24 小时以内的本地素材。')
        digest=fingerprint(path,self.runtime.cancel);after=path.stat()
        if (before.st_size,before.st_mtime_ns)!=(after.st_size,after.st_mtime_ns):raise UserError('素材读取期间发生变化，请稍后重试。')
        return Source(portable_path(path),ticks,after.st_size,digest)
    def verify(self,source,replacement=None):
        actual=self.inspect(replacement or source.file)
        if actual.size!=source.size or actual.sha256.lower()!=source.sha256.lower():raise UserError('所选文件与原素材不一致，请定位同一份文件。')
        # Same bytes can have sub-millisecond duration rounding differences across
        # decoders. Keep the project's timebase so existing edits never drift.
        actual.duration=source.duration;return actual
    def prepare(self,source):
        if self.preview_hash==source.sha256 and self.preview and self.preview.exists():return self.preview
        self.verify(source)
        target=self.runtime.cache/('preview-'+uuid.uuid4().hex+'.pcm')
        required=source.duration*4
        if shutil.disk_usage(self.runtime.cache).free<required+64*1024*1024:raise UserError(f'准备试听需要约 {required/1048576:.0f} MiB 临时磁盘空间，当前空间不足。')
        args=[self.runtime.binary('ffmpeg'),'-nostdin','-hide_banner','-v','error','-copyts','-start_at_zero','-i',source.file,'-map','0:a:0','-vn','-af','aresample=48000:async=1:first_pts=0,apad','-t',f'{source.duration/SCALE:.9f}','-ar','48000','-ac','2','-c:a','pcm_s16le','-f','s16le','-y',target]
        try:
            self.runtime.run(args)
            # Clamp/pad to the exact shared 48 kHz frame count, not the encoder's
            # packet boundaries. Padding is file based and never materialized in RAM.
            with target.open('r+b') as stream:stream.truncate(required)
        except BaseException:target.unlink(missing_ok=True);raise
        if self.preview:self.preview.unlink(missing_ok=True)
        self.preview=target;self.preview_hash=source.sha256;return target
    def decode16(self,source,target):
        preview=self.prepare(source)
        self.runtime.run([self.runtime.binary('ffmpeg'),'-nostdin','-hide_banner','-v','error','-f','s16le','-ar','48000','-ac','2','-i',preview,'-ar','16000','-ac','1','-c:a','pcm_s16le','-y',target])
    def waveform(self,source):
        path=self.prepare(source);n=max(1,math.ceil(source.duration/2048))
        filter=f'asetnsamples=n={n}:p=1,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-'
        raw=self.runtime.capture([self.runtime.binary('ffmpeg'),'-nostdin','-hide_banner','-v','error','-f','s16le','-ar','48000','-ac','2','-i',path,'-af',filter,'-f','null','-'],limit=2_000_000)
        values=[]
        for m in re.finditer(rb'lavfi\.astats\.Overall\.Peak_level=([^\r\n]+)',raw):
            try:value=10**(float(m[1])/20)
            except (ValueError,OverflowError):value=0
            values.append(min(1.0,max(0.0,value)))
        return values[:2048]
    def recognize(self,source,destination,language='zh',project_name='默认项目',prompt=''):
        if language not in ['zh','en','es','auto']:raise UserError('不支持的识别语言。')
        folder=new_output(destination,source,'字幕')
        try:
            with tempfile.TemporaryDirectory(prefix='recognize-',dir=self.runtime.cache) as temp:
                temp=Path(temp);wav=temp/'audio.wav';self.decode16(source,wav)
                self.runtime.run([self.runtime.binary('source-timed-whisper'),self.runtime.model('ggml-small.bin'),self.runtime.model('ggml-silero-v6.2.0.bin'),wav,folder/'识别原始结果.json',prompt,language],log=folder/'识别.log')
            raw=json.loads((folder/'识别原始结果.json').read_text(encoding='utf-8'))
            rows=[]
            from .core import stamp
            for row in raw.get('transcription',[]):
                value=row.get('text','').strip();a=row.get('offsets',{}).get('from',-1);b=row.get('offsets',{}).get('to',-1)
                if value and 0<=a<b and b*48<=source.duration+48:rows.append((a*48,min(b*48,source.duration),value))
            if not rows:raise UserError('没有识别出有效对白；请核对语言和音轨。')
            text=''.join(f'{i}\n{stamp(a)} --> {stamp(b)}\n{v}\n\n' for i,(a,b,v) in enumerate(rows,1))
            project=Project.make(source,text);plain=project.subtitles(project.timeline('original'))
            for name,data in [('字幕.srt',plain[0]),('学习基准.srt',plain[0]),('对白.txt',plain[1])]: (folder/name).write_text(data,encoding='utf-8')
            (folder/'本次词库.json').write_text(json.dumps({'version':VERSION,'language':language,'project':project_name,'prompt':prompt,'alignment':'source-vad-islands-v1'},ensure_ascii=False,indent=2),encoding='utf-8')
            return project,folder
        except BaseException:
            # Recognition logs aid retry; no source files or existing output are removed.
            raise
    def export(self,project,destination,mode='edited',format='m4a',names=False,audio=True):
        project.validate();timeline=project.timeline(mode)
        if not timeline.duration:raise UserError('没有保留的音频片段。')
        srt,txt=project.subtitles(timeline,names)
        self.verify(project.source)
        preview=self.prepare(project.source) if audio else None
        folder=new_output(destination,project.source,'原始素材' if mode=='original' else '剪辑结果')
        stem=folder.name
        try:
            if audio:
                if format not in ['wav','m4a']:raise UserError('请选择 WAV 或 M4A。')
                file=folder/(stem+'.'+format)
                codec=['-c:a','aac','-b:a','192k'] if format=='m4a' else ['-c:a','pcm_s16le','-rf64','auto']
                args=[self.runtime.binary('ffmpeg'),'-nostdin','-hide_banner','-v','error','-f','s16le','-ar','48000','-ac','2','-i','pipe:0',*codec,'-y',file]
                with (folder/'音频导出.log').open('wb') as log, preview.open('rb') as source:
                    process=self.runtime.start(args,stdin=subprocess.PIPE,stdout=log,stderr=log)
                    try:
                        for entry in timeline.entries:
                            source.seek(entry.source.start*4);remaining=entry.source.duration*4
                            while remaining:
                                self.runtime.check();chunk=source.read(min(65536,remaining))
                                if not chunk:raise UserError('临时音轨不完整，请重新导入素材。')
                                process.stdin.write(chunk);remaining-=len(chunk)
                        process.stdin.close();self.runtime.finish(process)
                    finally:
                        if process.poll() is None:
                            process.terminate();process.wait()
                        with self.runtime.lock:
                            if self.runtime.process is process:self.runtime.process=None
            if srt:
                (folder/(stem+'.srt')).write_text(srt,encoding='utf-8');(folder/(stem+'.txt')).write_text(txt,encoding='utf-8')
            (folder/'时间线映射.json').write_text(json.dumps({'timeScale':SCALE,'timeline':mode,'sourceSHA256':project.source.sha256,'durationTicks':timeline.duration,'entries':[{'clipID':e.clip,'sourceStart':str(e.source.start),'sourceEnd':str(e.source.end),'timelineStart':str(e.timeline.start),'timelineEnd':str(e.timeline.end)} for e in timeline.entries]},indent=2),encoding='utf-8')
            (folder/'导出核对说明.txt').write_text('音频与字幕共用同一时间映射。原素材未修改。\nM4A 可能有编码帧粒度差异；识别、分人和裁剪后的文字需要人工核对。\n',encoding='utf-8')
            return folder
        except BaseException:shutil.rmtree(folder,ignore_errors=True);raise

def new_output(destination,source,kind):
    stem=re.sub(r'[<>:"/\\|?*]','_',source.file.stem)[:40].strip(' .') or '素材'
    folder=Path(destination)/(stem+'_'+kind+'_'+datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:6])
    folder.mkdir();return folder
