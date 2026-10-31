"""Build an onedir native desktop application and a per-user Windows installer."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]

def component_archives(arch,runtime,translation,destination):
    destination.mkdir(parents=True,exist_ok=True)
    version='0.8.0';items={}
    groups={
        'audio':('音频读写与剪辑', ['ffmpeg'], [], ['runtime/ffmpeg/ffmpeg.exe','runtime/ffmpeg/ffprobe.exe']),
        'recognition':('中英西语识别',['asr'],['ggml-small.bin','ggml-silero-v6.2.0.bin'],['runtime/asr/source-timed-whisper.exe','runtime/models/ggml-small.bin','runtime/models/ggml-silero-v6.2.0.bin']),
        'speakers':('本地说话人区分',['speaker'],['campplus-zh-en.onnx'],['runtime/speaker/speaker-embeddings.exe','runtime/models/campplus-zh-en.onnx']),
        'translation':('本地翻译运行组件',[],[],['translation/tingting-translate.exe'])}
    for name,(title,folders,models,required) in groups.items():
        sources={}
        for folder in folders+['licenses']:
            for p in (runtime/folder).rglob('*'):
                if p.is_file():sources['runtime/'+p.relative_to(runtime).as_posix()]=p
        for model in models:sources['runtime/models/'+model]=runtime/'models'/model
        if name=='translation':
            for p in Path(translation).rglob('*'):
                if p.is_file():sources['translation/'+p.relative_to(translation).as_posix()]=p
        filename=f'TingTingBeast-{version}-{arch}-{name}.zip';archive=destination/filename
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for relative,p in sorted(sources.items()):z.write(p,relative)
        digest=hashlib.sha256()
        with archive.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
        items[name]={'title':title,'bytes':archive.stat().st_size,'sha256':digest.hexdigest(),
            'unpackedBytes':sum(p.stat().st_size for p in sources.values()),'files':sorted(sources),'required':required,
            'url':f'https://github.com/hhhggg136/local-mp3totxtsrt/releases/download/windows-v{version}/{filename}'}
    return {'version':version,'architecture':arch,'components':items}

def python_licenses(destination):
    import importlib.metadata
    destination.mkdir(parents=True,exist_ok=True)
    for name in ['pyinstaller','ctranslate2','sentencepiece','numpy','PyYAML','sacremoses','regex','click','joblib','tqdm']:
        try:dist=importlib.metadata.distribution(name)
        except importlib.metadata.PackageNotFoundError:continue
        for file in dist.files or []:
            if any(x in file.name.lower() for x in ['license','copying','notice']) and dist.locate_file(file).is_file():
                shutil.copy2(dist.locate_file(file),destination/(name+'-'+file.name))
    for file in [Path(sys.base_prefix)/'LICENSE.txt',Path(sys.base_prefix)/'LICENSE']:
        if file.is_file():shutil.copy2(file,destination/'Python-LICENSE.txt')

def package(arch,translation):
    stage=ROOT/'.local'/('win-'+arch);dist=stage/'dist';name='TingTingBeast'
    assets=stage/'assets';assets.mkdir(exist_ok=True)
    icon=assets/'listening-mascot.ico'
    with Image.open(ROOT/'launcher/assets/listening-mascot-a2.png') as image:
        image.save(icon,format='ICO',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
    subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--windowed',
        '--name',name,'--icon',str(icon),'--manifest',str(ROOT/'windows/native/app.manifest'),
        '--paths',str(ROOT/'windows'),'--distpath',str(dist),'--workpath',str(stage/'pyinstaller'),
        '--specpath',str(stage),str(ROOT/'windows/app.py')],check=True)
    app=dist/name
    catalog=component_archives(arch,stage/'runtime',translation,ROOT/'dist/windows/components'/arch)
    (app/'components.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
    (ROOT/'dist/windows/components'/arch/f'TingTingBeast-0.8.0-{arch}-components.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
    shutil.copytree(assets,app/'assets',dirs_exist_ok=True)
    shutil.copy2(Path(translation)/'translation-catalog.json',app/'translation-catalog.json')
    shutil.copy2(ROOT/'LICENSE',app/'LICENSE.txt')
    shutil.copy2(ROOT/'windows/README.md',app/'Windows-README.txt')
    python_licenses(app/'runtime/licenses/python')
    return app

def worker():
    stage=ROOT/'.local/translation-worker';stage.mkdir(parents=True,exist_ok=True)
    subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--console',
        '--name','tingting-translate','--manifest',str(ROOT/'windows/native/app.manifest'),
        '--collect-all','ctranslate2','--collect-all','sentencepiece',
        '--distpath',str(stage/'dist'),'--workpath',str(stage/'build'),'--specpath',str(stage),
        str(ROOT/'windows/translate_worker.py')],check=True)
    output=stage/'dist/tingting-translate';python_licenses(output/'licenses')
    shutil.copy2(ROOT/'windows/vendor_argos_bpe.py',output/'licenses/Argos-BPE-MIT.py')
    return output

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--arch',choices=['x64','arm64'])
    parser.add_argument('--translation');parser.add_argument('--worker',action='store_true');args=parser.parse_args()
    print(worker() if args.worker else package(args.arch,args.translation))
