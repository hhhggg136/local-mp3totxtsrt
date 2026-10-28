"""Release build records exact hashes of four official optional language packages."""
import json
from pathlib import Path
from build_runtime import download, sha
from tingting.translation import PAIRS

def build(output):
    cache=Path('.local/translation-downloads');cache.mkdir(parents=True,exist_ok=True)
    pinned=json.loads(Path(__file__).with_name('translation-catalog.json').read_text(encoding='utf-8'))
    result={}
    for pair,url in PAIRS.items():
        if pinned[pair]['url']!=url:raise ValueError('Package source differs from pinned catalog')
        file=download(url,cache/(pair+'.argosmodel'),pinned[pair]['sha256'])
        if file.stat().st_size!=pinned[pair]['bytes']:raise ValueError('Package size differs from pinned catalog')
        import zipfile
        with zipfile.ZipFile(file) as archive:
            if archive.testzip():raise ValueError('Corrupt package: '+pair)
            print(pair,archive.namelist()[:35],flush=True)
        result[pair]={'url':url,'sha256':sha(file),'bytes':file.stat().st_size}
    print(json.dumps(result,sort_keys=True),flush=True)
    Path(output).parent.mkdir(parents=True,exist_ok=True)
    Path(output).write_text(json.dumps(result,indent=2),encoding='utf-8')

if __name__=='__main__':
    import sys
    build(sys.argv[1])
