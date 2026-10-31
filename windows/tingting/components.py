"""Optional, pinned local components; streaming downloads and atomic installation."""
from pathlib import Path, PurePosixPath
import json
import os
import shutil
import stat
import tempfile
import urllib.request
import zipfile
from .core import UserError, fingerprint


class Components:
    def __init__(self, runtime):
        self.runtime=runtime
        self.root=Path(os.environ.get('TINGTING_COMPONENTS_DIR') or runtime.data/'components')
        catalog=runtime.root/'components.json'
        self.catalog=json.loads(catalog.read_text(encoding='utf-8')) if catalog.is_file() else {}

    def item(self, name):
        try:return self.catalog['components'][name]
        except KeyError:raise UserError('缺少组件目录，请重新安装主程序。')

    def folder(self, name):
        item=self.item(name)
        return self.root/(name+'-'+item['sha256'][:16])

    def ready(self, name):
        if not self.catalog:return True  # Older, complete offline installations.
        item=self.item(name)
        if all((self.runtime.root/p).is_file() for p in item['required']):return True
        folder=self.folder(name)
        try:
            marker=json.loads((folder/'installed.json').read_text(encoding='utf-8'))
            return marker['sha256']==item['sha256'] and all((folder/p).is_file() for p in item['required'])
        except (OSError,ValueError,KeyError):return False

    def resolve(self, relative):
        local=self.runtime.root/relative
        if local.is_file():return local
        for name,item in self.catalog.get('components',{}).items():
            if relative in item['files'] and self.ready(name):
                return self.folder(name)/relative
        raise UserError('缺少本地组件，请在“本地组件”中配置后重试。')

    def install(self, name, archive=None):
        if self.ready(name):return
        item=self.item(name);runtime=self.runtime
        self.root.mkdir(parents=True,exist_ok=True)
        required=item['unpackedBytes']+(item['bytes'] if archive is None else 0)+32*1024*1024
        if shutil.disk_usage(self.root).free<required:raise UserError('磁盘空间不足，请清理空间后重试；现有项目和组件保留。')
        with tempfile.TemporaryDirectory(prefix='install-',dir=self.root) as temp:
            temp=Path(temp);download=temp/'component.zip'
            if archive is None:
                if not item['url'].startswith('https://github.com/hhhggg136/local-mp3totxtsrt/releases/download/'):
                    raise UserError('组件下载来源不兼容。')
                request=urllib.request.Request(item['url'],headers={'User-Agent':'TingTingBeast/0.8'})
                with urllib.request.urlopen(request,timeout=30) as inp,download.open('xb') as out:
                    total=0
                    while True:
                        runtime.check();chunk=inp.read(1024*1024)
                        if not chunk:break
                        total+=len(chunk)
                        if total>item['bytes']:raise UserError('组件下载大小异常。')
                        out.write(chunk)
            else:download=Path(archive)
            runtime.check()
            if download.stat().st_size!=item['bytes'] or fingerprint(download,runtime.cancel)!=item['sha256']:
                raise UserError('组件不完整或校验失败；现有组件和项目保留，请重试或导入对应版本的组件包。')
            stage=temp/'extracted';stage.mkdir();seen=set();total=0
            with zipfile.ZipFile(download) as z:
                if len(z.infolist())>10000:raise UserError('组件文件数异常。')
                for member in z.infolist():
                    runtime.check();p=PurePosixPath(member.filename)
                    if p.is_absolute() or '..' in p.parts or '\\' in member.filename or ':' in member.filename or stat.S_ISLNK(member.external_attr>>16):
                        raise UserError('组件路径不安全。')
                    if member.is_dir():continue
                    if member.filename not in item['files'] or member.filename in seen:raise UserError('组件内容不兼容。')
                    seen.add(member.filename);total+=member.file_size
                    if total>item['unpackedBytes']:raise UserError('组件解压大小超限。')
                    target=stage.joinpath(*p.parts);target.parent.mkdir(parents=True,exist_ok=True)
                    with z.open(member) as inp,target.open('xb') as out:
                        while True:
                            runtime.check();chunk=inp.read(1024*1024)
                            if not chunk:break
                            out.write(chunk)
            if seen!=set(item['files']) or total!=item['unpackedBytes']:raise UserError('组件文件不完整。')
            (stage/'installed.json').write_text(json.dumps({'sha256':item['sha256']}),encoding='utf-8')
            destination=self.folder(name)
            if destination.exists():
                raise UserError('组件目录已存在但不完整，请移走该目录后重试：'+str(destination))
            os.replace(stage,destination)
