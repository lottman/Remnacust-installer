import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class NodeStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.container = {'Id': 'a' * 64, 'State': {'Running': False}, 'Mounts': [],
            'Config': {'Env': ['SECRET_KEY=fixture'], 'Labels': {
                'com.docker.compose.service': 'node',
                'com.docker.compose.project.working_dir': str(self.root)}}}
        self.config = {'services': {'node': {'image': 'new', 'volumes': []}}}
        self.calls = []

    def runner(self, args, **kwargs):
        self.calls.append(args)
        if args[1] == 'inspect':
            return types.SimpleNamespace(stdout=json.dumps([self.container]), returncode=0)
        return types.SimpleNamespace(stdout='', stderr='Error response from daemon: Could not find the file ' + args[3].split(':', 1)[1], returncode=1)

    @staticmethod
    def copy_state(runner):
        return lambda container, source, target: runner(['docker', 'cp', '-a', container + ':' + source + '/.', str(target)], capture_output=True, text=True, timeout=180)

    def plan(self):
        return runtime.plan_node_state(self.config, self.container, self.root)

    def test_missing_state_directories_get_private_mounts_and_missing_legacy_files_are_allowed(self):
        plan = self.plan()
        self.assertEqual(len(plan['copies']), 3)
        runtime.snapshot_node_state(plan, self.runner, self.copy_state(self.runner))
        self.assertEqual(len(self.calls), 4)
        for item in plan['copies']:
            self.assertTrue(Path(item['target']).is_dir())
            self.assertEqual(Path(item['target']).stat().st_mode & 0o777, 0o700)

    def test_existing_parent_and_named_mounts_are_preserved(self):
        self.container['Mounts'] = [{'Destination': '/var/lib', 'Type': 'volume', 'Source': 'existing', 'RW': True}]
        self.config['services']['node']['volumes'] = [{'type': 'volume', 'source': 'existing', 'target': '/var/lib'}]
        original = copy.deepcopy(self.config)
        plan = self.plan()
        self.assertEqual(self.config, original)
        self.assertEqual(plan['copies'], [])
        runtime.snapshot_node_state(plan, self.runner, self.copy_state(self.runner))
        self.assertEqual(self.calls, [])

    def test_running_source_and_read_only_state_are_rejected(self):
        plan = self.plan()
        self.container['State']['Running'] = True
        with self.assertRaises(runtime.ConfigurationError):
            runtime.snapshot_node_state(plan, self.runner, self.copy_state(self.runner))
        self.assertFalse(Path(plan['root']).exists())
        self.container['Mounts'] = [{'Destination': '/var/lib/remnanode', 'RW': False}]
        with self.assertRaises(runtime.ConfigurationError):
            self.plan()

    def test_daemon_failure_does_not_masquerade_as_absent_legacy_state(self):
        def run(args, **kwargs):
            if args[1] == 'inspect':
                return self.runner(args, **kwargs)
            return types.SimpleNamespace(returncode=1, stderr='permission denied', stdout='')
        with self.assertRaises(runtime.ConfigurationError):
            runtime.snapshot_node_state(self.plan(), run)

    def test_managed_core_digest_and_state_are_copied_before_replacement(self):
        binary = b'fixture core binary'
        digest = hashlib.sha256(binary).hexdigest()
        def run(args, **kwargs):
            if args[1] == 'inspect':
                return self.runner(args, **kwargs)
            destination = Path(args[-1])
            if destination.name == 'core-manager':
                (destination / digest).write_bytes(binary)
                (destination / 'state.json').write_text(json.dumps({'mode': 'managed', 'paused': True,
                    'binary': {'path': '/var/lib/remnawave/core-manager/' + digest, 'sha256': digest}}))
            return types.SimpleNamespace(returncode=0, stderr='', stdout='')
        plan = self.plan()
        runtime.snapshot_node_state(plan, run, self.copy_state(run))
        core = next(Path(item['target']) for item in plan['copies'] if item['target'].endswith('core-manager'))
        self.assertTrue(json.loads((core / 'state.json').read_text())['paused'])
        self.assertEqual((core / digest).read_bytes(), binary)

    def test_invalid_plan_cannot_write_outside_deployment(self):
        plan = self.plan()
        plan['root'] = str(self.root.parent / 'unrelated')
        with self.assertRaises(runtime.ConfigurationError):
            runtime.snapshot_node_state(plan, self.runner, self.copy_state(self.runner))

    def test_compose_comparison_allows_only_planned_state_paths(self):
        plan = self.plan()
        after = copy.deepcopy(self.container)
        after['Mounts'] = [{'Type':'bind', 'Source':item['target'], 'Destination':item['source'], 'RW':True} for item in plan['copies']]
        runtime.compare_environment(self.container, after)
        after['Mounts'][0]['Source'] = '/unrelated/private'
        with self.assertRaises(runtime.ConfigurationError):
            runtime.compare_environment(self.container, after)


if __name__ == '__main__':
    unittest.main()
