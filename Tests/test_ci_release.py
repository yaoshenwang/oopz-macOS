import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ci_release import validate_tag, validate_archive
from publish_release import validate
from build_channel import channel, dev_tag

class AutomatedReleaseTests(unittest.TestCase):
    def test_dev_identity_binds_source_and_does_not_accept_rc(self):
        tag = dev_tag('0.4.0', 'a' * 40, '123', '2')
        self.assertEqual(tag, 'v0.4.0-dev.123.2.gaaaaaaaaaaaa')
        self.assertEqual(channel(tag, '0.4.0', 'a' * 40), 'dev')
        self.assertEqual(channel('v0.4.0', '0.4.0'), 'stable')
        for invalid in ('v0.4.0-dev.123.0.gaaaaaaaaaaaa', 'v0.4.0-rc.1',
                        'v0.4.0-dev.123.2.gaaaaaaaaaaaa/extra', 'v0.4.1-dev.123.2.gaaaaaaaaaaaa'):
            with self.assertRaises(ValueError): channel(invalid, '0.4.0')
        with self.assertRaises(ValueError): channel(tag, '0.4.0', 'b' * 40)
        with self.assertRaises(ValueError): dev_tag('0.4.0', 'a' * 40, '1;echo', '1')

    def test_dev_cannot_enter_release_publisher_even_with_valid_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tag = dev_tag('0.4.0', 'a' * 40, '123', '1')
            for ext in ('zip', 'dmg'):
                (root / f'Oopz-{tag[1:]}-universal.{ext}').write_bytes(b'fixture')
            files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir()}
            metadata = {'version': tag[1:], 'channel': 'dev', 'sourceCommit': 'a' * 40,
                        'signing': 'Developer ID', 'notarized': True, 'files': files}
            (root / 'release.json').write_text(json.dumps(metadata))
            checks = dict(files, **{'release.json': hashlib.sha256((root / 'release.json').read_bytes()).hexdigest()})
            (root / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(checks.items())))
            (root / 'RELEASE_NOTES.md').write_text('Dev build')
            self.assertEqual(len(validate(root, tag, 'a' * 40, allow_dev=True)), 4)
            with self.assertRaises(ValueError): validate(root, tag, 'a' * 40)
            with self.assertRaises(ValueError): validate(root, tag, 'b' * 40, allow_dev=True)
            (root / f'Oopz-{tag[1:]}-universal.zip').write_bytes(b'tampered')
            with self.assertRaises(ValueError): validate(root, tag, 'a' * 40, allow_dev=True)

    def test_tag_must_match_version(self):
        validate_tag('v1.2.3', '1.2.3')
        for tag in ('v1.2.4', '1.2.3', 'v1.2.3;echo unsafe'):
            with self.assertRaises(ValueError): validate_tag(tag, '1.2.3')

    def test_archive_cannot_escape_or_include_private_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'input.zip'
            for name in ('../escape', '/absolute', 'identity.key', 'Oopz.app/../../escape'):
                with zipfile.ZipFile(archive, 'w') as output: output.writestr(name, b'fixture')
                with self.assertRaises(ValueError): validate_archive(archive)
            with zipfile.ZipFile(archive, 'w') as output:
                info = zipfile.ZipInfo('Oopz.app/link'); info.create_system = 3
                info.external_attr = 0o120777 << 16
                output.writestr(info, '/outside')
            with self.assertRaises(ValueError): validate_archive(archive)

    def test_publish_requires_notarized_exact_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for ext in ('zip', 'dmg'): (root / f'Oopz-1.2.3-universal.{ext}').write_bytes(b'fixture')
            files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir()}
            meta = {'version': '1.2.3', 'sourceCommit': 'a'*40, 'signing': 'Developer ID', 'notarized': True, 'files': files}
            def receipts():
                (root / 'release.json').write_text(json.dumps(meta))
                checks = dict(files, **{'release.json': hashlib.sha256((root/'release.json').read_bytes()).hexdigest()})
                (root / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(checks.items())))
                (root / 'RELEASE_NOTES.md').write_text('fixture')
            receipts()
            self.assertEqual(len(validate(root, 'v1.2.3', 'a'*40)), 4)
            with self.assertRaises(ValueError): validate(root, 'v1.2.3', 'b'*40)
            (root / 'identity.key').write_text('fixture')
            with self.assertRaises(ValueError): validate(root, 'v1.2.3', 'a'*40)
            (root / 'identity.key').unlink()
            meta['notarized'] = False; receipts()
            with self.assertRaises(ValueError): validate(root, 'v1.2.3', 'a'*40)
            meta['notarized'] = True; receipts()
            (root / 'Oopz-1.2.3-universal.zip').write_bytes(b'tampered')
            with self.assertRaises(ValueError): validate(root, 'v1.2.3', 'a'*40)

if __name__ == '__main__': unittest.main()
