import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import dispatch_dev


class DevDispatchTests(unittest.TestCase):
    def test_pr_and_tag_refs_cannot_request_privileged_build(self):
        for ref in ('refs/pull/1/merge', 'refs/heads/feature', 'refs/tags/v0.4.0'):
            with patch.dict(os.environ, {'GITHUB_REF': ref}), patch.object(dispatch_dev, 'api') as api:
                with self.assertRaises(ValueError): dispatch_dev.main()
                api.assert_not_called()

    def test_immutable_tag_and_explicit_dispatch_use_exact_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': 'a' * 40,
                   'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2',
                   'GITHUB_REPOSITORY': 'example/client', 'GITHUB_STEP_SUMMARY': tmp + '/summary'}
            with patch.dict(os.environ, env), patch.object(dispatch_dev, 'api') as api, \
                 patch.object(dispatch_dev.subprocess, 'check_output', return_value='a' * 40 + '\n'), \
                 patch.object(dispatch_dev.subprocess, 'run') as run:
                dispatch_dev.main()
                run.assert_called_once_with(['git', 'merge-base', '--is-ancestor', 'a' * 40, 'origin/main'], check=True)
                tag_payload = api.call_args_list[0].args[1]
                self.assertEqual(tag_payload['sha'], 'a' * 40)
                self.assertTrue(tag_payload['ref'].endswith('-dev.123.2.gaaaaaaaaaaaa'))
                self.assertEqual(api.call_args_list[1].args,
                                 ('repos/example/client/actions/workflows/release.yml/dispatches',
                                  {'ref': tag_payload['ref'].removeprefix('refs/tags/')}))

    def test_checkout_mismatch_stops_before_tag_creation(self):
        with patch.dict(os.environ, {'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': 'a' * 40}), \
             patch.object(dispatch_dev.subprocess, 'check_output', return_value='b' * 40), \
             patch.object(dispatch_dev, 'api') as api:
            with self.assertRaises(ValueError): dispatch_dev.main()
            api.assert_not_called()
