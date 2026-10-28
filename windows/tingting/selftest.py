"""Exercise the installed executable and real encoder; writes no production data."""
import ctypes
import json
import math
import os
from pathlib import Path
import struct
import tempfile
import wave
from .core import Project,History,SCALE,load_project,save_project
from .media import Runtime,Media

def peak_working_set():
    from ctypes import wintypes as W
    class Counters(ctypes.Structure):
        _fields_=[('cb',W.DWORD),('faults',W.DWORD)]+[(n,ctypes.c_size_t) for n in ['peak','current','pagedPeak','paged','nonpagedPeak','nonpaged','pagefile','pagefilePeak']]
    counters=Counters();counters.cb=ctypes.sizeof(counters)
    ctypes.windll.kernel32.GetCurrentProcess.restype=ctypes.c_void_p
    ctypes.windll.psapi.GetProcessMemoryInfo.argtypes=[ctypes.c_void_p,ctypes.POINTER(Counters),W.DWORD]
    if not ctypes.windll.psapi.GetProcessMemoryInfo(ctypes.windll.kernel32.GetCurrentProcess(),ctypes.byref(counters),counters.cb):raise OSError('Memory measurement failed')
    return counters.peak

def dominant(samples,rate):
    # Compare three known frequencies against real decoded PCM rather than
    # asserting an export implementation's own mapping JSON.
    return max([440,660,880,1100],key=lambda f:abs(sum(v*complex(math.cos(2*math.pi*f*i/rate),-math.sin(2*math.pi*f*i/rate)) for i,v in enumerate(samples))))

def main(report):
    report=Path(report);result={'passed':False};runtime=None
    try:
        with tempfile.TemporaryDirectory(prefix='听听兽 安装验证 ') as folder:
            root=Path(folder);runtime=Runtime(data=root/'data');media=Media(runtime)
            original=root/'三个声音.wav'
            runtime.run([runtime.binary('ffmpeg'),'-nostdin','-hide_banner','-v','error','-f','lavfi','-i',
                'aevalsrc=0.2*sin(2*PI*if(lt(t,4),440,if(lt(t,8),660,880))*t)|0.2*sin(2*PI*if(lt(t,4),660,if(lt(t,8),880,1100))*t):s=48000:d=12',
                '-c:a','pcm_s16le','-y',original])
            source=media.inspect(original)
            p=Project.make(source,'1\n00:00:01,000 --> 00:00:03,000\n第一段\n\n2\n00:00:05,000 --> 00:00:07,000\n第二段\n\n3\n00:00:09,000 --> 00:00:11,000\n第三段\n')
            h=History(p);h.move(p.order[2],0);h.delete(p.order[2])
            assert [(e.source.start,e.source.end) for e in p.timeline().entries]==[(384000,576000),(0,192000)]
            code=h.add_speaker();h.rename(code,'小王');h.assign(p.cues[0].id,code)
            save_project(p,root/'project.tingting');assert load_project(root/'project.tingting')==p
            outputs={}
            for kind in ['wav','m4a']:
                output=media.export(p,root,'edited',kind,True)
                file=next(output.glob('*.'+kind));decoded=root/(kind+'-decoded.wav')
                runtime.run([runtime.binary('ffmpeg'),'-nostdin','-hide_banner','-v','error','-i',file,'-c:a','pcm_s16le','-y',decoded])
                with wave.open(str(decoded),'rb') as w:
                    assert w.getnchannels()==2 and w.getframerate()==48000
                    assert abs(w.getnframes()-384000)<=2048
                    found=[]
                    for second in [1,5]:
                        w.setpos(second*48000);values=struct.unpack('<'+str(4096*2)+'h',w.readframes(4096))
                        found.append([dominant(values[::2],48000),dominant(values[1::2],48000)])
                    assert found==[[880,1100],[440,660]],found
                subtitle=next(output.glob('*.srt')).read_text(encoding='utf-8')
                assert '00:00:01,000 --> 00:00:03,000\n待确认：第三段' in subtitle
                assert '00:00:05,000 --> 00:00:07,000\n小王：第一段' in subtitle
                outputs[kind]={'frequenciesHz':found,'durationSeconds':8,'srtTimingVerified':True}
            assert media.verify(source).sha256==source.sha256
            result.update(realAudioExports=outputs,projectRoundtrip=True,sourceUnchanged=True)
            runtime.close();runtime=None
            # Create actual Tk widgets in the frozen executable, with no global
            # developer Python packages and no production user data directory.
            os.environ['LOCAL_SUBTITLE_DATA_DIR']=str(root/'gui-data')
            import tkinter as tk
            from .gui import Workspace
            window=tk.Tk();workspace=Workspace(window);window.update()
            workspace.wave=[.5]*2048;workspace.install(p);window.update()
            assert len(workspace.tree.get_children())==3
            workspace.player.stop();workspace.runtime.close();window.destroy()
            result.update(guiCreated=True,guiAndExportProcessPeakWorkingSetBytes=peak_working_set(),passed=True)
    except Exception as exc:
        import traceback
        result['error']=str(exc);result['traceback']=traceback.format_exc()
    finally:
        if runtime:runtime.close()
        report.parent.mkdir(parents=True,exist_ok=True);report.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    if not result['passed']:raise SystemExit(1)
