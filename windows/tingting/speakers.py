"""Cue-level local speaker candidates. Embeddings are temporary, not enrollment."""
import math
import array
import struct
import tempfile
from pathlib import Path
from .core import UserError, Cancelled, fingerprint

def normalize(values):
    if not values or not all(math.isfinite(x) for x in values):return None
    n=math.sqrt(sum(x*x for x in values))
    return array.array('f',(x/n for x in values)) if n>0.000001 else None

def cosine(a,b):return sum(x*y for x,y in zip(a,b))

def group(cues,vectors,expected=0,cancel=None):
    if not 0<=expected<=8:raise UserError('预计人数须为自动或 1–8 人。')
    known={c.id for c in cues};windows={};notes={};features={}
    if len(vectors)>len(cues)*3:raise UserError('说话人结果过大。')
    for id,v in vectors:
        if id not in known or len(v)!=192:raise UserError('说话人结果与字幕不匹配。')
        value=normalize(v)
        if value:windows.setdefault(id,[]).append(value)
    overlap=set();chain=[];end=0
    for cue in sorted(cues,key=lambda c:c.span.start):
        if cue.span.start>=end:
            if len(chain)>1:overlap.update(chain)
            chain=[]
        chain.append(cue.id);end=max(end,cue.span.end)
    if len(chain)>1:overlap.update(chain)
    for cue in cues:
        if cue.id in overlap:notes[cue.id]='字幕区间与其他对白重叠，需人工核对';continue
        values=windows.get(cue.id,[])
        if not values:notes[cue.id]='声音过短、过轻或无法分析';continue
        if any(cosine(values[0],v)<.45 for v in values):notes[cue.id]='同一句声音变化较大，可能有多人或干扰';continue
        features[cue.id]=normalize([sum(row[i] for row in values) for i in range(192)])
    usable=sorted((c for c in cues if features.get(c.id)),key=lambda c:(-c.span.duration,c.span.start))
    centers=[];counts=[]
    def check():
        if cancel is not None and cancel.is_set():raise Cancelled('分人已取消。')
    if expected and usable:
        centers=[features[usable[0].id]]
        while len(centers)<min(expected,len(usable)):
            v=min((features[c.id] for c in usable),key=lambda v:max(cosine(v,x) for x in centers))
            if max(cosine(v,x) for x in centers)>=.99999:break
            centers.append(v)
        for _ in range(12):
            check();sums=[[0.0]*192 for _ in centers]
            for cue in usable:
                v=features[cue.id];k=max(range(len(centers)),key=lambda i:cosine(v,centers[i]))
                sums[k]=[x+y for x,y in zip(sums[k],v)]
            centers=[normalize(sums[i]) or centers[i] for i in range(len(centers))]
    else:
        for cue in usable:
            check();v=features[cue.id]
            k=max(range(len(centers)),key=lambda i:cosine(v,centers[i])) if centers else None
            if k is not None and cosine(v,centers[k])>=.55:
                centers[k]=normalize([x*counts[k]+y for x,y in zip(centers[k],v)]);counts[k]+=1
            elif len(centers)<26:centers.append(v);counts.append(1)
    labels={}
    for cue in usable:
        check();v=features[cue.id];rank=sorted(range(len(centers)),key=lambda i:cosine(v,centers[i]),reverse=True)
        if not rank:continue
        score=cosine(v,centers[rank[0]]);margin=score-cosine(v,centers[rank[1]]) if len(rank)>1 else 1
        if score>=.45 and margin>=.06:labels[cue.id]=rank[0]
        else:notes[cue.id]='声音相似或干扰较大，无法可靠区分'
    codes={};result={'speakers':[],'assignments':{},'model':'sherpa-onnx-2.0.1/campplus-zh-en-v1'}
    for cue in sorted(cues,key=lambda c:c.span.start):
        k=labels.get(cue.id)
        if k is not None:
            if k not in codes:
                id=chr(65+len(codes));codes[k]=id;result['speakers'].append({'id':id,'name':id})
            assignment={'speakerID':codes[k],'manual':False,'note':'自动结果，请试听核对'}
        else:assignment={'speakerID':None,'manual':False,'note':notes.get(cue.id,'待确认')}
        result['assignments'][cue.id]=assignment
    return result

def analyze(project,media,expected=0):
    if not project.cues:raise UserError('请先载入对应 SRT。')
    media.verify(project.source)
    runtime=media.runtime;model=runtime.model('campplus-zh-en.onnx')
    with tempfile.TemporaryDirectory(prefix='speakers-',dir=runtime.cache) as temp:
        temp=Path(temp);wav=temp/'audio.wav';ranges=temp/'ranges.tsv';out=temp/'vectors.bin';stats=temp/'stats.json'
        media.decode16(project.source,wav)
        ranges.write_text('\n'.join(f'{c.id}\t{c.span.start}\t{c.span.end}' for c in project.cues),encoding='utf-8')
        runtime.run([runtime.binary('speaker-embeddings'),model,wav,ranges,out,stats],log=temp/'speaker.log')
        vectors=[]
        with out.open('rb') as stream:
            if stream.read(8)!=b'TTSPK001':raise UserError('说话人结果格式不正确。')
            while True:
                raw=stream.read(804)
                if not raw:break
                if len(raw)!=804 or len(vectors)>=len(project.cues)*3:raise UserError('说话人结果不完整。')
                vectors.append((raw[:36].decode('ascii'),array.array('f',struct.unpack('<192f',raw[36:]))))
        import json
        metrics=json.loads(stats.read_text(encoding='utf-8'))
        return group(project.cues,vectors,expected,runtime.cancel),metrics
