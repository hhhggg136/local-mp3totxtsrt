"""Optional verified local language packs and cue-preserving offline translation."""
from __future__ import annotations
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import tempfile
import urllib.request
import zipfile
from .core import UserError, fingerprint, stamp
from .media import new_output

PAIRS={'zh_en':'https://argos-net.com/v1/translate-zh_en-1_9.argosmodel',
       'en_zh':'https://argos-net.com/v1/translate-en_zh-1_9.argosmodel',
       'en_es':'https://argos-net.com/v1/translate-en_es-1_0.argosmodel',
       'es_en':'https://argos-net.com/v1/translate-es_en-1_9.argosmodel'}

def route(source,target):
    if source not in ['zh','en','es'] or target not in ['zh','en','es'] or source==target:
        raise UserError('请选择不同的中文、英语或西班牙语。')
    return [source+'_'+target] if 'en' in [source,target] else [source+'_en','en_'+target]

class Translation:
    def __init__(self,runtime):
        self.runtime=runtime;self.root=runtime.data/'language-packs';self.root.mkdir(exist_ok=True)
        catalog=runtime.root/'translation-catalog.json'
        self.catalog=json.loads(catalog.read_text(encoding='utf-8')) if catalog.is_file() else {}
    def metadata(self,pair):
        item=self.catalog.get(pair)
        if not item or item.get('url')!=PAIRS.get(pair) or len(item.get('sha256',''))!=64:
            raise UserError('安装包缺少语言包校验目录，请使用完整安装包。')
        return item
    def missing(self,source,target):
        return [(p,self.metadata(p)) for p in route(source,target) if not (self.root/p/'verified.json').is_file()]
    def install(self,pair,archive=None):
        item=self.metadata(pair);runtime=self.runtime
        with tempfile.TemporaryDirectory(prefix='language-',dir=runtime.cache) as temp:
            temp=Path(temp);file=Path(archive) if archive else temp/'package.zip'
            if archive is None:
                request=urllib.request.Request(item['url'],headers={'User-Agent':'TingTingBeast/0.7'})
                with urllib.request.urlopen(request,timeout=45) as response,file.open('xb') as out:
                    count=0
                    while True:
                        runtime.check();chunk=response.read(1024*1024)
                        if not chunk:break
                        count+=len(chunk)
                        if count>item['bytes']:raise UserError('语言包下载大小异常，请重试。')
                        out.write(chunk)
            if file.stat().st_size!=item['bytes'] or fingerprint(file,runtime.cancel)!=item['sha256']:
                raise UserError('语言包下载不完整或校验失败；现有词库和项目保留，可重新下载或导入。')
            stage=temp/'extracted';stage.mkdir();total=0
            with zipfile.ZipFile(file) as z:
                if len(z.infolist())>5000:raise UserError('语言包文件数异常。')
                for member in z.infolist():
                    runtime.check();name=PurePosixPath(member.filename)
                    if name.is_absolute() or '..' in name.parts or '\\' in member.filename or ':' in member.filename or stat.S_ISLNK(member.external_attr>>16):raise UserError('语言包路径不安全。')
                    total+=member.file_size
                    if total>2_000_000_000:raise UserError('语言包解压大小超限。')
                    target=stage.joinpath(*name.parts)
                    if member.is_dir():target.mkdir(parents=True,exist_ok=True);continue
                    target.parent.mkdir(parents=True,exist_ok=True)
                    with z.open(member) as inp,target.open('xb') as out:shutil.copyfileobj(inp,out,1024*1024)
            candidates=list(stage.glob('*/metadata.json'))+list(stage.glob('metadata.json'))
            if len(candidates)!=1:raise UserError('语言包结构不兼容。')
            package=candidates[0].parent;metadata=json.loads(candidates[0].read_text(encoding='utf-8'))
            if metadata.get('from_code','')+'_'+metadata.get('to_code','')!=pair or not (package/'model/model.bin').is_file() or not any((package/n).is_file() for n in ['spm.model','sentencepiece.model','bpe.model']):raise UserError('语言包不兼容。')
            # Per-file hashes detect changes to extracted weights on subsequent jobs.
            hashes={str(p.relative_to(package).as_posix()):fingerprint(p,runtime.cancel) for p in package.rglob('*') if p.is_file()}
            (package/'verified.json').write_text(json.dumps({'archiveSHA256':item['sha256'],'files':hashes}),encoding='utf-8')
            destination=self.root/pair
            if destination.exists():
                # Existing packs are never replaced silently; remove only our own
                # incomplete installation, which has no verified marker.
                if (destination/'verified.json').exists():return destination
                shutil.rmtree(destination)
            shutil.move(str(package),str(destination));return destination
    def verify(self,pair):
        package=self.root/pair;item=self.metadata(pair)
        try:
            verification=json.loads((package/'verified.json').read_text(encoding='utf-8'))
            if verification['archiveSHA256']!=item['sha256']:raise ValueError()
            for name,digest in verification['files'].items():
                relative=PurePosixPath(name)
                if relative.is_absolute() or '..' in relative.parts or fingerprint(package.joinpath(*relative.parts),self.runtime.cancel)!=digest:raise ValueError()
        except (OSError,ValueError,KeyError):raise UserError('本地语言包校验失败，请移走损坏的语言包后重新安装。')
        return package
    def translate(self,project,destination,source,target,mode='original',names=False,translations=None):
        rows=project.projected(project.timeline(mode))
        if not rows:raise UserError('当前时间线没有可翻译的对白。')
        texts=[row[0].text for row in rows]
        if len(json.dumps(texts,ensure_ascii=False).encode('utf-8'))>7_000_000:raise UserError('单次翻译正文过大，请拆分字幕。')
        metrics=[]
        for pair in route(source,target):
            package=self.verify(pair);self.runtime.check()
            with tempfile.TemporaryDirectory(prefix='translate-',dir=self.runtime.cache) as temp:
                temp=Path(temp);request=temp/'input.json';output=temp/'output.json'
                request.write_text(json.dumps({'package':str(package),'texts':texts},ensure_ascii=False),encoding='utf-8')
                worker=self.runtime.resolve('translation/tingting-translate.exe')
                env={'CT2_FORCE_CPU_ISA':'GENERIC'} if platform.machine().lower() in ['arm64','aarch64'] else {}
                log=temp/'worker.log'
                with log.open('wb') as handle:
                    process=self.runtime.start([worker,request,output],stdout=handle,stderr=handle,env=env)
                    try:self.runtime.finish(process)
                    except UserError:
                        if output.is_file():
                            data=json.loads(output.read_text(encoding='utf-8'))
                            if data.get('error'):raise UserError(data['error'])
                        raise
                if output.stat().st_size>16_000_000:raise UserError('翻译结果过大。')
                data=json.loads(output.read_text(encoding='utf-8'));texts=data.get('texts',[])
                if len(texts)!=len(rows) or any(not isinstance(t,str) or not t.strip() for t in texts):raise UserError('翻译结果条数不完整。')
                metrics.append({'pair':pair,'peakWorkingSetBytes':data.get('peakWorkingSetBytes')})
        folder=new_output(destination,project.source,'译文_'+target)
        plain=[];bilingual=[];txt=[]
        for i,((cue,_,span,_),text) in enumerate(zip(rows,texts),1):
            prefix=project.label(cue.id)+'：' if names and project.speakers is not None else ''
            header=f'{i}\n{stamp(span.start)} --> {stamp(span.end)}\n'
            plain.append(header+prefix+text+'\n\n');bilingual.append(header+prefix+cue.text+'\n'+text+'\n\n')
            txt.append(f'[{stamp(span.start)} → {stamp(span.end)}] {prefix}{text}\n')
        try:
            for name,text in [('译文.srt',''.join(plain)),('双语.srt',''.join(bilingual)),('译文.txt',''.join(txt))]:(folder/name).write_text(text,encoding='utf-8')
            (folder/'翻译说明.json').write_text(json.dumps({'source':source,'target':target,'viaEnglish':'en' not in [source,target], 'timeline':mode,'cues':len(rows),'engine':'CTranslate2/Argos local','sourceSHA256':project.source.sha256,'workerMetrics':metrics},ensure_ascii=False,indent=2),encoding='utf-8')
            return folder
        except BaseException:shutil.rmtree(folder,ignore_errors=True);raise
