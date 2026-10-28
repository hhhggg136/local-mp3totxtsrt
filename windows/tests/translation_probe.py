"""Real frozen-worker translation, all six directions and twelve subtitle exports."""
import copy
import json
from pathlib import Path
import shutil
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tingting.core import Project,Source,SCALE,parse_srt
from tingting.media import Runtime
from tingting.translation import Translation,PAIRS

worker=Path(sys.argv[1]).resolve();report=Path(sys.argv[2]).resolve()
phrases={'zh':'你好，今天我们一起去公园。','en':'Hello, today we are going to the park together.','es':'Hola, hoy vamos juntos al parque.'}
results=[]
with tempfile.TemporaryDirectory(prefix='翻译 实测 ') as temp:
    root=Path(temp);app=root/'app';app.mkdir();shutil.copytree(worker,app/'translation')
    shutil.copy2(worker/'translation-catalog.json',app/'translation-catalog.json')
    runtime=Runtime(root=app,data=root/'data');translator=Translation(runtime)
    try:
        for pair in PAIRS:translator.install(pair,Path('.local/translation-downloads')/(pair+'.argosmodel'))
        for source in phrases:
            for target in phrases:
                if source==target:continue
                print('TRANSLATION_DIRECTION='+source+'_'+target,flush=True)
                p=Project.make(Source(str(root/'source.wav'),4*SCALE,0,'a'*64),f'1\n00:00:01,000 --> 00:00:03,000\n{phrases[source]}\n')
                before=copy.deepcopy(p);folder=translator.translate(p,root,source,target)
                plain=parse_srt((folder/'译文.srt').read_text(encoding='utf-8'))
                bilingual=parse_srt((folder/'双语.srt').read_text(encoding='utf-8'))
                assert p==before and len(plain)==len(bilingual)==1
                assert plain[0].span==bilingual[0].span==p.cues[0].span
                assert bilingual[0].text==phrases[source]+'\n'+plain[0].text
                assert plain[0].text.strip() and '\ufffd' not in plain[0].text
                print('TRANSLATION_RESULT='+plain[0].text,flush=True)
                metrics=json.loads((folder/'翻译说明.json').read_text(encoding='utf-8'))
                assert all(m['peakWorkingSetBytes']>0 for m in metrics['workerMetrics'])
                results.append({'source':source,'target':target,'original':phrases[source],'translation':plain[0].text,'timecodesUnchanged':True,'sourcePreserved':True,**metrics})
    finally:runtime.close()
report.parent.mkdir(parents=True,exist_ok=True);report.write_text(json.dumps({'passed':True,'directions':results},ensure_ascii=False,indent=2),encoding='utf-8')
