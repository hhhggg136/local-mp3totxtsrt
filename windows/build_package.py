"""Build an onedir native desktop application and a per-user Windows installer."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]

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
    app=dist/name;shutil.copytree(stage/'runtime',app/'runtime',dirs_exist_ok=True)
    shutil.copytree(assets,app/'assets',dirs_exist_ok=True)
    shutil.copytree(translation,app/'translation',dirs_exist_ok=True)
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
