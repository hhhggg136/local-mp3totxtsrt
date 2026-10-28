"""Independent timing, persistence and bounded playback checks; no audio device needed."""
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tingting.core import History, Project, Source, Span, SCALE, UserError, load_project, save_project
from tingting.player import TimelineReader


class TimelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.source = self.folder / '原素材.wav'
        self.source.write_bytes(b'preserve original')
        self.project = Project.make(Source(str(self.source), 12*SCALE, 17, 'a'*64),
            '1\n00:00:02,000 --> 00:00:03,000\n第一句\n\n'
            '2\n00:00:06,000 --> 00:00:07,000\n第二句\n\n'
            '3\n00:00:10,000 --> 00:00:11,000\n第三句\n')

    def test_reorder_delete_and_srt_share_exact_map(self):
        p = self.project
        first, second, third = p.order
        h = History(p)
        h.move(third, 0)
        h.delete(second)
        timeline = p.timeline()
        self.assertEqual([(e.source.start/SCALE, e.source.end/SCALE) for e in timeline.entries],
                         [(8.5, 12), (0, 4.5)])
        self.assertEqual(timeline.duration, 8*SCALE)
        self.assertEqual(timeline.source_at(0), 408000)
        self.assertEqual(timeline.source_at(168000), 0)
        self.assertIsNone(timeline.source_at(384000))
        srt, _ = p.subtitles(timeline)
        self.assertEqual(srt, '1\n00:00:01,500 --> 00:00:02,500\n第三句\n\n'
                         '2\n00:00:05,500 --> 00:00:06,500\n第一句\n\n')
        original, _ = p.subtitles(p.timeline('original'))
        self.assertIn('00:00:06,000 --> 00:00:07,000', original)
        h.undo(); h.undo()
        self.assertEqual(p.order, [first, second, third])
        self.assertFalse(next(c for c in p.clips if c.id == second).deleted)

    def test_trim_retains_text_and_requests_review(self):
        p = self.project
        h = History(p)
        h.trim(p.order[0], Span(120000, 216000))
        cue, clip, span, review = p.projected(p.timeline())[0]
        self.assertEqual((span.start, span.end), (0, 24000))
        self.assertEqual(cue.text, '第一句')
        self.assertTrue(review)
        h.review(clip.id)
        self.assertFalse(p.projected(p.timeline())[0][3])
        h.undo(); h.undo()
        self.assertEqual(p.clips[0].span, Span(0, 216000))

    def test_cross_platform_speaker_roundtrip_and_backup(self):
        p = self.project
        h = History(p)
        code = h.add_speaker()
        h.rename(code, '小王')
        h.assign(p.cues[0].id, code)
        obj = p.json()
        self.assertIsInstance(obj['speakerData']['assignments'], list)
        self.assertEqual(Project.from_json(json.loads(json.dumps(obj))), p)
        target = self.folder / '剪辑.tingting'
        save_project(p, target)
        before = copy.deepcopy(p)
        h.text(p.cues[0].id, '修正后')
        save_project(p, target)
        self.assertEqual(load_project(target), p)
        self.assertEqual(load_project(str(target)+'.bak'), before)
        self.assertEqual(self.source.read_bytes(), b'preserve original')
        with self.assertRaises(UserError): save_project(p, self.source)

    def test_reader_reads_reordered_intervals_without_loading_recording(self):
        # Four stereo frames represent two distinct two-frame clips.
        from tingting.core import Entry, Timeline
        raw = self.folder / 'audio.pcm'
        raw.write_bytes(b''.join(struct.pack('<hh', v, -v) for v in [11, 22, 33, 44]))
        timeline = Timeline([Entry('b', Span(2,4), Span(0,2)), Entry('a', Span(0,2), Span(2,4))])
        reader = TimelineReader(raw, timeline)
        self.addCleanup(reader.close)
        self.assertEqual(struct.unpack('<hhhhhh', reader.read(3)), (33,-33,44,-44,11,-11))
        self.assertEqual(struct.unpack('<hh', reader.read(100)), (22,-22))
        self.assertEqual(reader.read(1), b'')


if __name__ == '__main__': unittest.main()
