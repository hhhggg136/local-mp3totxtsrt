"""Behavioral checks for consent-based hints and uncertain speaker assignments."""
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tingting.learning import LearningStore
from tingting.core import Cue,Span,new_id
from tingting.speakers import group

class LearningTests(unittest.TestCase):
    def test_correction_is_isolated_disabled_and_import_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            store=LearningStore(Path(temp)/'learning.sqlite3')
            try:
                before='1\n00:00:01,000 --> 00:00:03,000\n今天去公圆散步\n'
                after=before.replace('公圆','公园')
                self.assertEqual(store.import_pair(before,after,'项目甲')['learned'],1)
                self.assertTrue(store.import_pair(before,after,'项目甲')['duplicate'])
                self.assertEqual(store.prompt('项目甲'),'')
                id=store.entries('项目甲')[0][0];store.approve(id,True)
                self.assertIn('公园',store.prompt('项目甲'))
                self.assertEqual(store.prompt('项目乙'),'')
                store.edit(id,'公园散步');self.assertEqual(store.prompt('项目甲'),'')
                shifted=after.replace('00:00:01,000','00:00:01,100')
                self.assertEqual(store.import_pair(before,shifted,'项目甲')['unmatched'],1)
                self.assertEqual(len(store.entries('项目甲')),1)
            finally:store.close()

class SpeakerTests(unittest.TestCase):
    def test_repeated_voices_share_code_and_overlap_stays_unassigned(self):
        cues=[Cue(new_id(),Span(a,b),'句子','句子') for a,b in [(0,48000),(96000,144000),(192000,240000),(288000,360000),(336000,384000)]]
        a=[1.0]+[0.0]*191;b=[0.0,1.0]+[0.0]*190
        data=group(cues,[(cues[i].id,v) for i,v in enumerate([a,b,a,b,a])],2)
        ids=[data['assignments'][c.id]['speakerID'] for c in cues]
        self.assertEqual(ids,['A','B','A',None,None])
        self.assertIn('重叠',data['assignments'][cues[3].id]['note'])

if __name__=='__main__':unittest.main()
