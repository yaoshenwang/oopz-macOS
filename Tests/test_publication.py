import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from audit_public import inspect_bytes, inspect_path
from manifest import tree

class PublicationTests(unittest.TestCase):
    def test_secret_shapes_and_split_keys(self):
        self.assertIn('jwt', inspect_bytes(b'eyJ' + b'a' * 12 + b'.' + b'b' * 12 + b'.' + b'c' * 12))
        pem = b'-----BEGIN ' + b'PRIVATE KEY-----'
        self.assertIn('private-key', inspect_bytes(pem))
        split = b'"MII' + b'A' * 61 + b'" +\n' + (b'"' + b'B' * 64 + b'" +\n') * 10
        self.assertIn('encoded-key-material', inspect_bytes(split))
    def test_identifiers_and_file_boundaries(self):
        home = b'/' + b'Users' + b'/test-person/source.swift'
        self.assertIn('absolute-home-path', inspect_bytes(home))
        self.assertIn('private-local-denylist', inspect_bytes(b'private-value', [b'private-value']))
        self.assertTrue(inspect_path('captures/test.txt'))
        self.assertTrue(inspect_path('session.json'))
        self.assertFalse(inspect_bytes(b'contributors@users.noreply.github.com'))
    def test_resource_and_symlink_mutation_changes_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); resource = root / 'resource'; resource.write_bytes(b'original')
            before = tree(root); resource.write_bytes(b'tampered')
            self.assertNotEqual(before, tree(root))
            (root / 'link').symlink_to('resource')
            before = tree(root); (root / 'link').unlink(); (root / 'link').symlink_to('elsewhere')
            self.assertNotEqual(before, tree(root))

if __name__ == '__main__': unittest.main()
