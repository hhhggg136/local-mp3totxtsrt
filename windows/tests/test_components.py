"""Real ZIP lifecycle: offline/online installation, integrity and cancellation."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from unittest.mock import Mock
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tingting.components import Components
from tingting.media import Runtime
from tingting.core import Cancelled,UserError


class ComponentTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.app=self.root/'app';self.app.mkdir()
        self.archive=self.root/'audio.zip'
        self.files={'runtime/ffmpeg/ffmpeg.exe':b'fixture encoder','runtime/ffmpeg/helper.dll':b'fixture library'}
        self.write_archive(self.files)
        self.runtime=Runtime(root=self.app,data=self.root/'data');self.addCleanup(self.runtime.close)
        self.manager=Components(self.runtime)

    def write_archive(self,files):
        with zipfile.ZipFile(self.archive,'w') as z:
            for name,content in files.items():z.writestr(name,content)
        item={'title':'Audio','bytes':self.archive.stat().st_size,'unpackedBytes':sum(map(len,files.values())),
              'sha256':hashlib.sha256(self.archive.read_bytes()).hexdigest(),'files':list(files),
              'required':['runtime/ffmpeg/ffmpeg.exe'],'url':'https://github.com/hhhggg136/local-mp3totxtsrt/releases/download/test/audio.zip'}
        (self.app/'components.json').write_text(json.dumps({'components':{'audio':item}}))

    def test_offline_import_resolves_without_copying_into_application(self):
        m=self.manager;self.assertFalse(m.ready('audio'))
        m.install('audio',self.archive)
        self.assertTrue(m.ready('audio'))
        self.assertEqual(self.runtime.resolve('runtime/ffmpeg/ffmpeg.exe').read_bytes(),self.files['runtime/ffmpeg/ffmpeg.exe'])
        self.assertFalse((self.app/'runtime/ffmpeg/ffmpeg.exe').exists())
        with patch('urllib.request.urlopen',side_effect=AssertionError('No repeated download')):m.install('audio')

    def test_corrupt_archive_can_retry_without_losing_existing_data(self):
        self.archive.write_bytes(b'broken')
        with self.assertRaises(UserError):self.manager.install('audio',self.archive)
        self.assertFalse(self.manager.ready('audio'))
        self.write_archive(self.files);self.manager=Components(self.runtime)
        self.manager.install('audio',self.archive);self.assertTrue(self.manager.ready('audio'))
        self.assertEqual(list(self.manager.root.glob('install-*')),[])

    def test_streaming_download_and_cancellation(self):
        with patch('urllib.request.urlopen',return_value=io.BytesIO(self.archive.read_bytes())):
            self.manager.install('audio')
        self.assertTrue(self.manager.ready('audio'))
        other=Runtime(root=self.app,data=self.root/'other');self.addCleanup(other.close)
        other.cancel.set()
        with self.assertRaises(Cancelled):Components(other).install('audio',self.archive)
        self.assertEqual(list((other.data/'components').glob('install-*')),[])

    def test_signed_catalog_does_not_allow_path_traversal(self):
        self.write_archive({'../outside':b'bad'})
        with self.assertRaises(UserError):Components(self.runtime).install('audio',self.archive)
        self.assertFalse((self.root/'outside').exists())

    def test_existing_full_installation_is_reused_without_network(self):
        for name,data in self.files.items():
            p=self.app/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        with patch('urllib.request.urlopen',side_effect=AssertionError('Must reuse local files')):
            self.manager.install('audio')
        self.assertEqual(self.runtime.resolve('runtime/ffmpeg/ffmpeg.exe'),self.app/'runtime/ffmpeg/ffmpeg.exe')

    def test_gui_cancel_does_not_start_download(self):
        from tingting.gui import Workspace
        workspace=Workspace.__new__(Workspace)
        workspace.runtime=self.runtime;workspace.root=Mock();workspace.task=Mock()
        with patch('tingting.gui.boxes.askyesnocancel',return_value=None) as confirm,patch('urllib.request.urlopen',side_effect=AssertionError('Must require consent')):
            self.assertTrue(workspace.ensure_components(['audio']))
        workspace.task.assert_not_called()
        self.assertIn('MiB',confirm.call_args.args[1])
        self.assertIn(str(self.manager.root),confirm.call_args.args[1])
