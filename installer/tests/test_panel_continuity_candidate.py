import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('continuity', Path(__file__).resolve().parents[1] / 'panel_continuity.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CandidateTests(unittest.TestCase):
    def run_case(self, mode='ready'):
        calls = []
        current, candidate = 'a' * 64, 'b' * 64
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'inspect.json'
            source.write_text(json.dumps([{'Id': current, 'Config': {'Env': ['DATABASE_URL=private-sentinel', 'APP_SECRET=private-key']}}]))
            def run(args, **kwargs):
                calls.append(args)
                if args[1] == 'create':
                    env_file = Path(args[args.index('--env-file') + 1])
                    self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
                    self.assertIn('DATABASE_URL=private-sentinel', env_file.read_text())
                    self.assertNotIn('private-sentinel', ' '.join(args))
                    self.assertIn('--read-only', args)
                    self.assertIn('--cap-drop=ALL', args)
                    self.assertIn('--security-opt=no-new-privileges', args)
                    self.assertIn('container:' + current, args)
                    self.assertNotIn('--privileged', args)
                    self.assertNotIn('--volume', args)
                    return subprocess.CompletedProcess(args, 0, candidate, '')
                if args[1] == 'start':
                    if mode == 'timeout': raise subprocess.TimeoutExpired(args, 130)
                    if mode == 'error': raise subprocess.CalledProcessError(1, args, stderr='private-sentinel')
                    return subprocess.CompletedProcess(args, 0, '3' if mode == 'ready' else 'private-sentinel', '')
                return subprocess.CompletedProcess(args, 0)
            with patch.object(module.subprocess, 'run', side_effect=run):
                if mode == 'ready': self.assertEqual(module.run_probe(source, 'image@sha256:' + 'c' * 64), 3)
                else: self.assertRaises(Exception, module.run_probe, source, 'image@sha256:' + 'c' * 64)
            self.assertEqual(calls[-1], ['docker', 'rm', '--force', candidate])
            self.assertNotIn(['docker', 'rm', '--force', current], calls)

    def test_legacy_panel_uses_candidate_without_stopping_current_app(self): self.run_case()
    def test_failure_timeout_and_invalid_output_cleanup_only_candidate(self):
        for mode in ['error', 'timeout', 'invalid']:
            with self.subTest(mode=mode): self.run_case(mode)

    def test_multiline_environment_and_unsafe_image_are_rejected_before_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'inspect.json'
            source.write_text(json.dumps([{'Id': 'a' * 64, 'Config': {'Env': ['BAD=one\ntwo']}}]))
            with patch.object(module.subprocess, 'run') as run:
                self.assertRaises(ValueError, module.run_probe, source, 'safe-image')
                self.assertRaises(ValueError, module.run_probe, source, '--privileged')
                run.assert_not_called()


if __name__ == '__main__': unittest.main()
