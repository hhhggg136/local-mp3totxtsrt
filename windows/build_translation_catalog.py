"""Release build records exact hashes of four official optional language packages."""
import json
from pathlib import Path
from build_runtime import download, sha
from tingting.translation import PAIRS

def build(output):
    cache=Path('.local/translation-downloads');cache.mkdir(parents=True,exist_ok=True)
    result={}
    for pair,url in PAIRS.items():
        file=download(url,cache/(pair+'.argosmodel'))
        import zipfile
        with zipfile.ZipFile(file) as archive:
            if archive.testzip():raise ValueError('Corrupt package: '+pair)
        result[pair]={'url':url,'sha256':sha(file),'bytes':file.stat().st_size}
    Path(output).parent.mkdir(parents=True,exist_ok=True)
    Path(output).write_text(json.dumps(result,indent=2),encoding='utf-8')

if __name__=='__main__':
    import sys
    build(sys.argv[1])
