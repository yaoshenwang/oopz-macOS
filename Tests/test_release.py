import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from release import validate_receipts

class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.source = {'commit': 'a' * 40, 'dirty': False, 'files': {'source.swift': 'source-digest'}}
        self.files = {'Contents/MacOS/Oopz': 'binary-digest', 'Contents/Resources/sound.wav': 'resource-digest'}
        self.build = {'source': self.source, 'signing': 'local-developer-id', 'files': self.files}
        self.validation = {'pass': True, 'sourceCommit': self.source['commit'], 'files': self.files,
                           'sha256': 'binary-digest', 'steps': [{'mode': '--smoke', 'pass': True}, {'mode': '--media-test', 'pass': True}]}
        self.acceptance = {'sourceCommit': self.source['commit'], 'sha256': 'binary-digest',
                           **{k: 'pass' for k in ['fullscreen', 'stop', 'window', 'late_join', 'system_audio']}}
    def check(self):
        validate_receipts(self.build, self.validation, self.files, self.source, self.acceptance)
    def test_matching_receipts(self): self.check()
    def test_dirty_source(self):
        self.source['dirty'] = True
        with self.assertRaises(ValueError): self.check()
    def test_source_change(self):
        self.source = copy.deepcopy(self.source); self.source['files']['source.swift'] = 'new'
        with self.assertRaises(ValueError): self.check()
    def test_resource_tampering(self):
        self.files = dict(self.files); self.files['Contents/Resources/sound.wav'] = 'new'
        with self.assertRaises(ValueError): self.check()
    def test_missing_media_test(self):
        self.validation['steps'].pop()
        with self.assertRaises(ValueError): self.check()
    def test_failed_validation(self):
        self.validation['pass'] = False
        with self.assertRaises(ValueError): self.check()
    def test_pending_manual_acceptance(self):
        self.acceptance['late_join'] = 'pending'
        with self.assertRaises(ValueError): self.check()
    def test_old_acceptance(self):
        self.acceptance['sha256'] = 'another-binary'
        with self.assertRaises(ValueError): self.check()

if __name__ == '__main__': unittest.main()
