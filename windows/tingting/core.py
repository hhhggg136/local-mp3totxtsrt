"""Portable metadata and the single 48 kHz edit/playback/export time map."""
from __future__ import annotations
import bisect
import copy
import hashlib
import json
import math
import os
import re
import tempfile
import uuid
from dataclasses import dataclass, field
from pathlib import Path

SCALE = 48000
MAX_TICKS = 31536000 * SCALE

class UserError(Exception):
    pass

class Cancelled(UserError):
    pass

def new_id():
    return str(uuid.uuid4()).upper()

def stamp(ticks):
    ms = max(0, (int(ticks) + 24) // 48)
    return f'{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d},{ms%1000:03d}'

def parse_stamp(value):
    match = re.fullmatch(r'(\d{2,}):(\d{2}):(\d{2})[,.](\d{3})', value.strip())
    if not match:
        raise UserError('字幕时间码格式不正确。')
    h,m,s,ms = map(int, match.groups())
    if h >= 8760 or m >= 60 or s >= 60:
        raise UserError('字幕时间码超出范围。')
    return ((h*60+m)*60+s)*SCALE+ms*48

def seconds_ticks(value):
    text = str(value).strip()
    if not re.fullmatch(r'\d{1,8}(\.\d{1,3})?', text):
        raise UserError('时间请输入非负秒数，最多三位小数。')
    whole, _, fraction = text.partition('.')
    result = int(whole)*SCALE+int((fraction+'000')[:3])*48
    if result >= MAX_TICKS:
        raise UserError('时间超出范围。')
    return result

def parse_srt(text):
    if len(text.encode('utf-8')) > 5_000_000:
        raise UserError('单份字幕最多支持 5 MB。')
    text = text.replace('\r\n','\n').replace('\r','\n').strip('\ufeff \t\n')
    blocks = re.split(r'\n[ \t]*\n', text) if text else []
    if not 0 < len(blocks) <= 10000:
        raise UserError('请输入有效 SRT，最多 10000 条。')
    result = []
    for block in blocks:
        lines = block.splitlines()
        if len(lines) < 3 or not lines[0].strip().isdigit() or lines[1].count('-->') != 1:
            raise UserError('SRT 条目需要序号、时间码和正文。')
        a,b = map(parse_stamp, lines[1].split('-->'))
        content = '\n'.join(lines[2:]).strip()
        if b <= a or not content or len(content) > 4000:
            raise UserError('字幕时长或正文不符合要求。')
        result.append(Cue(new_id(), Span(a,b), content, content))
    return result

def read_srt(path):
    path = Path(path)
    if path.stat().st_size > 5_000_000:
        raise UserError('单份字幕最多支持 5 MB。')
    return path.read_text(encoding='utf-8-sig')

def fingerprint(path, cancel=None):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while True:
            if cancel is not None and cancel.is_set():
                raise Cancelled('任务已取消。')
            block = stream.read(1024*1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()

def portable_path(path):
    value = Path(path).resolve().as_posix()
    # POSIX absolute form also passes existing Mac project validation. Relink on
    # the other OS; source SHA-256 must still match before installing a project.
    return '/' + value if re.match(r'^[A-Za-z]:/', value) else value

def local_path(value):
    if os.name == 'nt' and re.match(r'^/[A-Za-z]:/', value):
        value = value[1:]
    return Path(value)

@dataclass(eq=True)
class Span:
    start: int
    end: int
    @property
    def duration(self):
        return self.end-self.start
    def intersect(self, other):
        a,b = max(self.start,other.start), min(self.end,other.end)
        return Span(a,b) if b>a else None
    def json(self):
        return {'start':self.start,'end':self.end}

@dataclass(eq=True)
class Source:
    path: str
    duration: int
    size: int
    sha256: str
    @property
    def file(self):
        return local_path(self.path)
    def json(self):
        return {'path':self.path,'durationTicks':self.duration,'fileSize':self.size,'sha256':self.sha256}

@dataclass(eq=True)
class Cue:
    id: str
    span: Span
    original: str
    text: str
    def json(self):
        return {'id':self.id,'range':self.span.json(),'originalText':self.original,'text':self.text}

@dataclass(eq=True)
class Clip:
    id: str
    initial: Span
    span: Span
    cues: list
    deleted: bool=False
    boundary: str='automaticMidpoint'
    confirmed: bool=False
    def json(self):
        return {'id':self.id,'initial':self.initial.json(),'range':self.span.json(),'dialogueIDs':self.cues,
                'deleted':self.deleted,'boundaryOrigin':self.boundary,'textReviewConfirmed':self.confirmed}

@dataclass(eq=True)
class Entry:
    clip: str
    source: Span
    timeline: Span

class Timeline:
    def __init__(self, entries):
        self.entries = entries
        self.ends = [e.timeline.end for e in entries]
        self.by_clip = {e.clip:e for e in entries}
        self.duration = self.ends[-1] if self.ends else 0
    def at(self, tick):
        if not 0 <= tick < self.duration:
            return None
        i = bisect.bisect_right(self.ends,tick)
        return self.entries[i] if i<len(self.entries) and tick>=self.entries[i].timeline.start else None
    def source_at(self, tick):
        e = self.at(tick)
        return e.source.start+tick-e.timeline.start if e else None

@dataclass(eq=True)
class Project:
    source: Source
    cues: list
    clips: list
    order: list
    speakers: dict | None=None
    @classmethod
    def make(cls, source, subtitle=None):
        cues = sorted(parse_srt(subtitle),key=lambda c:c.span.start) if subtitle else []
        groups, ends = [], []
        for cue in cues:
            if cue.span.start<0 or cue.span.end>source.duration:
                raise UserError('字幕时间码超出素材，请确认字幕与音视频相对应。')
            if ends and cue.span.start<ends[-1]:
                groups[-1].append(cue); ends[-1]=max(ends[-1],cue.span.end)
            else:
                groups.append([cue]);ends.append(cue.span.end)
        clips=[]
        for i,g in enumerate(groups):
            start = 0 if i==0 else (ends[i-1]+g[0].span.start)//2
            end = source.duration if i==len(groups)-1 else (ends[i]+groups[i+1][0].span.start)//2
            clips.append(Clip(new_id(),Span(start,end),Span(start,end),[c.id for c in g]))
        if not clips:
            clips=[Clip(new_id(),Span(0,source.duration),Span(0,source.duration),[])]
        p=cls(source,cues,clips,[c.id for c in clips]);p.validate();return p
    def validate(self):
        s=self.source
        if not (s.path.startswith('/') or re.match(r'^[A-Za-z]:[\\/]',s.path)) or type(s.duration) is not int or not 0<s.duration<MAX_TICKS or type(s.size) is not int or s.size<0 or not re.fullmatch('[a-fA-F0-9]{64}',s.sha256):
            raise UserError('项目素材信息不正确。')
        cids=[c.id for c in self.cues];ids=[c.id for c in self.clips]
        if not 0<=len(cids)<=10000 or len(set(cids))!=len(cids) or not 0<len(ids)<=10000 or len(set(ids))!=len(ids) or len(set(self.order))!=len(ids) or set(self.order)!=set(ids):
            raise UserError('项目片段或顺序不正确。')
        for key in cids+ids:
            try: uuid.UUID(key)
            except (ValueError,TypeError,AttributeError): raise UserError('项目 ID 不正确。')
        cue_index={c.id:c for c in self.cues};assigned=[];end=0
        for clip in sorted(self.clips,key=lambda c:c.initial.start):
            a,b=clip.initial,clip.span
            if any(type(v) is not int for v in [a.start,a.end,b.start,b.end]) or a.start!=end or a.end<=a.start or not a.start<=b.start<b.end<=a.end or clip.boundary not in ['automaticMidpoint','manual']:
                raise UserError('项目片段范围不正确。')
            end=a.end
            for id in clip.cues:
                cue=cue_index.get(id)
                if not cue or any(type(v) is not int for v in [cue.span.start,cue.span.end]) or not a.start<=cue.span.start<cue.span.end<=a.end or not cue.text.strip() or max(len(cue.text),len(cue.original))>4000:
                    raise UserError('对白与片段不匹配。')
                assigned.append(id)
        if end!=s.duration or len(assigned)!=len(cids) or set(assigned)!=set(cids):
            raise UserError('项目原始时间线不完整。')
        if self.speakers is not None:
            people=self.speakers.get('speakers',[]);assignments=self.speakers.get('assignments',{})
            codes=[p['id'] for p in people]
            if len(codes)>26 or len(set(codes))!=len(codes) or any(x not in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' or len(x)!=1 for x in codes):
                raise UserError('说话人编号不正确。')
            if any(not valid_name(p['name']) for p in people) or not set(assignments)<=set(cids):
                raise UserError('说话人信息不正确。')
            if any(a.get('speakerID') not in codes+[None] or len(a.get('note',''))>200 for a in assignments.values()):
                raise UserError('说话人归属不正确。')
    def timeline(self, mode='edited'):
        index={c.id:c for c in self.clips};cursor=0;entries=[]
        ids=[c.id for c in sorted(self.clips,key=lambda c:c.initial.start)] if mode=='original' else self.order
        for id in ids:
            clip=index[id]
            if mode!='original' and clip.deleted: continue
            span=clip.initial if mode=='original' else clip.span
            entries.append(Entry(id,span,Span(cursor,cursor+span.duration)));cursor+=span.duration
        return Timeline(entries)
    def projected(self, timeline):
        ci={c.id:c for c in self.clips};di={c.id:c for c in self.cues};result=[]
        for entry in timeline.entries:
            clip=ci[entry.clip]
            for id in clip.cues:
                cue=di[id];remaining=cue.span.intersect(entry.source)
                if remaining:
                    start=entry.timeline.start+remaining.start-entry.source.start
                    result.append((cue,clip,Span(start,start+remaining.duration),remaining!=cue.span and not clip.confirmed))
        return sorted(result,key=lambda row:row[2].start)
    def label(self, cue):
        if self.speakers is None: return ''
        id=self.speakers.get('assignments',{}).get(cue,{}).get('speakerID')
        return next((p['name'] for p in self.speakers['speakers'] if p['id']==id),'待确认')
    def subtitles(self, timeline, names=False):
        srt,txt=[],[]
        for i,(cue,_,span,_) in enumerate(self.projected(timeline),1):
            a,b=stamp(span.start),stamp(span.end)
            if a==b: raise UserError('有字幕不足 1 毫秒，请调整边界。')
            prefix=self.label(cue.id)+'：' if names and self.speakers is not None else ''
            content='\n'.join(cue.text.splitlines())
            srt.append(f'{i}\n{a} --> {b}\n{prefix}{content}\n\n')
            txt.append(f'[{a} → {b}] {prefix}'+ ' / '.join(cue.text.splitlines())+'\n')
        return ''.join(srt),''.join(txt)
    def json(self):
        result={'schemaVersion':2 if self.speakers is not None else 1,'source':self.source.json(),'dialogues':[c.json() for c in self.cues], 'clips':[c.json() for c in self.clips],'order':self.order}
        if self.speakers is not None:
            data=copy.deepcopy(self.speakers);items=[]
            # Swift Codable UUID-key dictionaries use alternating key/value arrays.
            for id,value in data['assignments'].items():items.extend([id,value])
            data['assignments']=items;result['speakerData']=data
        return result
    @classmethod
    def from_json(cls, obj):
        try:
            if obj['schemaVersion'] not in [1,2]:raise UserError('项目版本不兼容。')
            s=obj['source'];source=Source(s['path'],s['durationTicks'],s['fileSize'],s['sha256'])
            cues=[Cue(c['id'],Span(**c['range']),c['originalText'],c['text']) for c in obj['dialogues']]
            clips=[Clip(c['id'],Span(**c['initial']),Span(**c['range']),c['dialogueIDs'],c['deleted'],c['boundaryOrigin'],c['textReviewConfirmed']) for c in obj['clips']]
            people=copy.deepcopy(obj.get('speakerData'))
            if people is not None:
                raw=people.get('assignments',{})
                if isinstance(raw,list):
                    if len(raw)%2:raise UserError('说话人数据不完整。')
                    raw=dict(zip(raw[::2],raw[1::2]))
                people['assignments']=raw
            if (people is not None)!=(obj['schemaVersion']==2):raise UserError('项目版本与说话人数据不一致。')
            project=cls(source,cues,clips,obj['order'],people);project.validate();return project
        except (KeyError,TypeError,ValueError,AttributeError) as exc:
            raise UserError('无法读取剪辑项目。') from exc

def valid_name(value):
    return isinstance(value,str) and bool(value.strip()) and len(value)<=40 and not any(c in ':：\r\n' or ord(c)<32 for c in value)

def atomic_write(path, data):
    path=Path(path);fd,name=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)

def load_project(path):
    path=Path(path)
    if path.stat().st_size>16_000_000:raise UserError('项目文件超过 16 MB。')
    return Project.from_json(json.loads(path.read_text(encoding='utf-8-sig')))

def same_file(a,b):
    a,b=Path(a),Path(b)
    return a.resolve()==b.resolve() or (a.exists() and b.exists() and os.path.samefile(a,b))

def save_project(project,path):
    project.validate();path=Path(path);backup=path.with_name(path.name+'.bak')
    if same_file(path,project.source.file) or same_file(backup,project.source.file):raise UserError('不能覆盖原素材。')
    data=json.dumps(project.json(),ensure_ascii=False,indent=2).encode('utf-8')
    if len(data)>16_000_000:raise UserError('项目超过 16 MB，请使用较小素材。')
    if path.exists():
        if path.stat().st_size>16_000_000:raise UserError('目标文件过大，不会覆盖。')
        atomic_write(backup,path.read_bytes())
    atomic_write(path,data)

class History:
    """50 small inverse commands; no PCM or complete project snapshots."""
    def __init__(self, project):
        project.validate();self.project=project;self.undo_stack=[];self.redo_stack=[]
    def _commit(self,op):
        self._apply(op,True);self.undo_stack.append(op);self.undo_stack=self.undo_stack[-50:];self.redo_stack=[]
    def _apply(self,op,forward):
        p=self.project;kind,key,old,new=op;value=new if forward else old
        if kind=='move':p.order.remove(key);p.order.insert(value,key)
        elif kind=='delete':next(c for c in p.clips if c.id==key).deleted=value
        elif kind=='trim':
            c=next(c for c in p.clips if c.id==key);c.span,c.boundary,c.confirmed=copy.deepcopy(value)
        elif kind=='text':next(c for c in p.cues if c.id==key).text=value
        elif kind=='review':next(c for c in p.clips if c.id==key).confirmed=value
        elif kind=='rename':next(s for s in p.speakers['speakers'] if s['id']==key)['name']=value
        elif kind=='speaker_add':
            if forward:
                if p.speakers is None:p.speakers={'speakers':[],'assignments':{},'model':'manual'}
                p.speakers['speakers'].append(copy.deepcopy(new))
            elif old is None:p.speakers=None
            else:p.speakers['speakers']=[s for s in p.speakers['speakers'] if s['id']!=key]
        elif kind=='assign':
            if forward:
                if p.speakers is None:p.speakers={'speakers':[],'assignments':{},'model':'manual'}
                p.speakers['assignments'][key]=copy.deepcopy(new)
            elif old is None:p.speakers=None
            elif old[1] is None:p.speakers['assignments'].pop(key,None)
            else:p.speakers['assignments'][key]=copy.deepcopy(old[1])
    def move(self,id,index):
        a=self.project.order.index(id)
        if 0<=index<len(self.project.order) and a!=index:self._commit(('move',id,a,index))
    def delete(self,id,value=True):
        c=next(c for c in self.project.clips if c.id==id)
        if c.deleted!=value:self._commit(('delete',id,c.deleted,value))
    def trim(self,id,span):
        c=next(c for c in self.project.clips if c.id==id)
        if not c.initial.start<=span.start<span.end<=c.initial.end:raise UserError('边界必须在该片段初始范围内。')
        if c.span!=span:self._commit(('trim',id,(copy.copy(c.span),c.boundary,c.confirmed),(span,'manual',False)))
    def text(self,id,value):
        value=value.strip();c=next(c for c in self.project.cues if c.id==id)
        if not value or len(value)>4000:raise UserError('对白文字须为 1–4000 个字。')
        if value!=c.text:self._commit(('text',id,c.text,value))
    def review(self,id,value=True):
        c=next(c for c in self.project.clips if c.id==id)
        if value!=c.confirmed:self._commit(('review',id,c.confirmed,value))
    def add_speaker(self):
        people=self.project.speakers
        used={p['id'] for p in people['speakers']} if people else set()
        id=next((c for c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' if c not in used),None)
        if id is None:raise UserError('最多 26 个说话人。')
        self._commit(('speaker_add',id,False if people is not None else None,{'id':id,'name':id}));return id
    def rename(self,id,name):
        name=name.strip()
        if not valid_name(name):raise UserError('名字须为 1–40 个字，不能包含冒号或换行。')
        p=next(x for x in self.project.speakers['speakers'] if x['id']==id)
        if p['name']!=name:self._commit(('rename',id,p['name'],name))
    def assign(self,id,speaker):
        data=self.project.speakers
        if id not in {c.id for c in self.project.cues} or (speaker is not None and (data is None or speaker not in {s['id'] for s in data['speakers']})):raise UserError('请选择当前项目内的说话人。')
        old=(True,copy.deepcopy(data['assignments'].get(id))) if data is not None else None
        self._commit(('assign',id,old,{'speakerID':speaker,'manual':True,'note':'人工纠正' if speaker else '人工设为待确认'}))
    def install_speakers(self,data):
        old=self.project.speakers;self.project.speakers=data
        try:self.project.validate()
        except BaseException:self.project.speakers=old;raise
        self.undo_stack=[];self.redo_stack=[]
    def undo(self):
        if self.undo_stack:
            op=self.undo_stack.pop();self._apply(op,False);self.redo_stack.append(op)
    def redo(self):
        if self.redo_stack:
            op=self.redo_stack.pop();self._apply(op,True);self.undo_stack.append(op)
