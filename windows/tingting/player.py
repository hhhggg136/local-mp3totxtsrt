"""Windows WinMM playback from the shared timeline, with three small buffers."""
import os
import threading
import time
from .core import UserError,SCALE

if os.name=='nt':
 import ctypes as C
 from ctypes import wintypes as W
 class Format(C.Structure):
  _pack_=1
  _fields_=[('tag',W.WORD),('channels',W.WORD),('rate',W.DWORD),('bytes_sec',W.DWORD),('align',W.WORD),('bits',W.WORD),('extra',W.WORD)]
 class Header(C.Structure):
  _fields_=[('data',C.c_void_p),('length',W.DWORD),('recorded',W.DWORD),('user',C.c_size_t),('flags',W.DWORD),('loops',W.DWORD),('next',C.c_void_p),('reserved',C.c_size_t)]
 class MMTime(C.Structure):
  _fields_=[('type',W.DWORD),('value',W.DWORD),('extra',W.DWORD)]
 winmm=C.WinDLL('winmm')
 winmm.waveOutOpen.argtypes=[C.POINTER(C.c_void_p),W.UINT,C.POINTER(Format),C.c_size_t,C.c_size_t,W.DWORD]
 for name in ['waveOutPrepareHeader','waveOutUnprepareHeader','waveOutWrite']:
  getattr(winmm,name).argtypes=[C.c_void_p,C.POINTER(Header),W.UINT]
 for name in ['waveOutReset','waveOutClose']:
  getattr(winmm,name).argtypes=[C.c_void_p]
 winmm.waveOutGetPosition.argtypes=[C.c_void_p,C.POINTER(MMTime),W.UINT]

class TimelineReader:
 def __init__(self,file,timeline,start=0,end=None):
  self.file=open(file,'rb');self.timeline=timeline;self.position=start;self.end=timeline.duration if end is None else min(end,timeline.duration)
 def read(self,frames):
  output=bytearray()
  while frames and self.position<self.end:
   entry=self.timeline.at(self.position)
   if entry is None:break
   count=min(frames,entry.timeline.end-self.position,self.end-self.position)
   self.file.seek((entry.source.start+self.position-entry.timeline.start)*4)
   chunk=self.file.read(count*4)
   if len(chunk)!=count*4:raise UserError('试听缓存不完整，请重新导入素材。')
   output.extend(chunk);self.position+=count;frames-=count
  return bytes(output)
 def close(self):self.file.close()

class Player:
 def __init__(self):
  self.position=0;self.playing=False;self.error=None;self.thread=None;self.stop_event=threading.Event();self.lock=threading.Lock()
 def seek(self,ticks):self.stop();self.position=max(0,int(ticks))
 def stop(self):
  self.stop_event.set()
  if self.thread and self.thread is not threading.current_thread():self.thread.join(timeout=5)
  self.thread=None;self.playing=False
 def play(self,file,timeline,start,end=None):
  if os.name!='nt':raise UserError('实际音频播放需要 Windows。')
  self.stop()
  if winmm.waveOutGetNumDevs()==0:raise UserError('Windows 没有可用的音频输出设备，请检查音箱或虚拟机音频。')
  self.stop_event=threading.Event();self.error=None;self.position=start;self.playing=True
  self.thread=threading.Thread(target=self._run,args=(file,timeline,start,end,self.stop_event),daemon=True);self.thread.start()
 def _run(self,file,timeline,start,end,stop):
  handle=C.c_void_p();fmt=Format(1,2,SCALE,SCALE*4,4,16,0);queue=[];reader=None;opened=False
  try:
   result=winmm.waveOutOpen(C.byref(handle),0xFFFFFFFF,C.byref(fmt),0,0,0)
   if result:raise UserError('无法打开 Windows 音频输出设备。')
   opened=True;reader=TimelineReader(file,timeline,start,end);ended=False
   while not stop.is_set():
    while queue and queue[0][0].flags&1:
     header,buffer=queue.pop(0);winmm.waveOutUnprepareHeader(handle,C.byref(header),C.sizeof(header))
    while len(queue)<3 and not ended:
     data=reader.read(4096)
     if not data:ended=True;break
     buffer=C.create_string_buffer(data);header=Header(C.cast(buffer,C.c_void_p),len(data),0,0,0,0,None,0)
     if winmm.waveOutPrepareHeader(handle,C.byref(header),C.sizeof(header)) or winmm.waveOutWrite(handle,C.byref(header),C.sizeof(header)):
      raise UserError('音频设备拒绝了试听数据。')
     queue.append((header,buffer))
    moment=MMTime(2,0,0)
    if not winmm.waveOutGetPosition(handle,C.byref(moment),C.sizeof(moment)):
     samples=moment.value if moment.type==2 else (moment.value//4 if moment.type==4 else moment.value*SCALE//1000)
     self.position=min(reader.end,start+samples)
    if ended and not queue:self.position=reader.end;break
    time.sleep(.01)
  except Exception as exc:self.error=str(exc)
  finally:
   if opened:
    winmm.waveOutReset(handle)
    for header,buffer in queue:winmm.waveOutUnprepareHeader(handle,C.byref(header),C.sizeof(header))
    winmm.waveOutClose(handle)
   if reader:reader.close()
   self.playing=False
