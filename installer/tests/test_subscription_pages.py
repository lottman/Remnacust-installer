import copy
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import subscription_pages as pages


class PagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        previous = os.environ.get('REMNACUST_ROOT')
        os.environ['REMNACUST_ROOT'] = str(self.root)
        self.addCleanup(lambda: os.environ.pop('REMNACUST_ROOT', None) if previous is None else os.environ.__setitem__('REMNACUST_ROOT', previous))
        self.directory = self.root / 'page'
        self.directory.mkdir()
        self.compose = self.directory / 'docker-compose.yml'
        self.compose.write_text(json.dumps({'services': {'page': {'image': 'page:old', 'environment': {'SECRET': 'fixture'}}}}))
        self.item = {'directory': str(self.directory), 'project': 'test-page', 'service': 'page', 'composeFiles': [str(self.compose)], 'domain': 'sub.example.test'}
        self.id = pages.identity(self.item)
        runtime.write(self.root / 'registry/subscription-pages' / (self.id + '.json'), self.item)

    def test_only_registered_ids_and_services_are_allowed(self):
        self.assertEqual(pages.selected(self.root, self.id), self.item)
        for value in ('../panel', self.id + ';reboot', 'a' * 24, None):
            with self.assertRaises(ValueError):
                pages.selected(self.root, value)
        for operation in ('exec', 'down', 'rm', '--help'):
            with self.assertRaises(ValueError):
                pages.service(self.root, self.id, operation)

    def test_helper_loads_in_the_isolated_cli_used_by_the_installer(self):
        root = self.root / 'empty'
        root.mkdir()
        result = subprocess.run([sys.executable, '-I', pages.__file__, 'list', '--root', str(root)], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_listing_never_returns_credentials_or_host_paths(self):
        container = {'Config': {'Image': 'page:current', 'Env': ['TOKEN=private']}, 'State': {'Running': True, 'Status': 'running'}}
        with patch.object(pages, 'inspect', return_value=container):
            result = pages.listing(self.root)
        self.assertTrue(result[0]['running'])
        text = json.dumps(result)
        self.assertNotIn('private', text)
        self.assertNotIn(str(self.directory), text)

    def test_companion_is_discovered_and_deduplicated(self):
        state = {**self.item, 'component': 'panel', 'subscriptionPage': True}
        runtime.write(self.root / 'registry/panel.json', state)
        records = pages.records(self.root)
        self.assertEqual(len(records), 2)
        self.assertTrue(any(x.get('companion') for x in records.values()))

    def test_install_rejects_insecure_remote_url_and_preserves_existing_files(self):
        for endpoint in ('http://panel.example.test', 'https://user:secret@panel.example.test', 'https://panel.example.test/api', 'file:///etc/shadow'):
            with self.assertRaises(ValueError):
                pages.install(self.root, self.directory, 'page', endpoint, 'a.b.c', '3010', 'page:new')
        with self.assertRaises(ValueError):
            pages.install(self.root, self.directory, 'page', 'https://panel.example.test', 'a.b.c', '3010', 'page:new')
        self.assertIn('fixture', self.compose.read_text())

    def test_install_uses_loopback_private_env_and_recoverable_registry(self):
        target = self.root / 'new-page'
        with patch.object(pages, 'command', return_value=''), patch.object(pages, 'ready'):
            page = pages.install(self.root, target, 'new-page', 'https://panel.example.test', 'a.b.c', '3011', 'page:new')
        config = runtime.load(target / 'docker-compose.yml')
        self.assertEqual(config['services']['subscription-page']['ports'], ['127.0.0.1:3011:3010'])
        self.assertNotIn('a.b.c', json.dumps(config))
        self.assertIn('REMNAWAVE_API_TOKEN=a.b.c', (target / '.env').read_text())
        self.assertIn(page, pages.records(self.root))

    def test_install_does_not_reuse_an_existing_compose_project(self):
        target = self.root / 'new-page'
        with patch.object(pages, 'command', return_value='existing-container'):
            with self.assertRaisesRegex(ValueError, 'COMPOSE_PROJECT_EXISTS'):
                pages.install(self.root, target, 'new-page', 'https://panel.example.test', 'a.b.c', '3011', 'page:new')
        self.assertFalse(target.exists())

    def test_update_keeps_stopped_state_and_rolls_back_on_failed_readiness(self):
        before = self.compose.read_text()
        calls = []
        def command(base, *args, **kwargs):
            calls.append([*base, *args])
            if '--format' in args:
                return before
            return ''
        with patch.object(pages, 'command', side_effect=command), patch.object(pages, 'inspect', return_value={'State': {'Running': False}}):
            pages.upgrade(self.root, self.id, 'page:new', '1.2.93', 'v1.2.93')
        self.assertTrue(any('--no-start' in call for call in calls))
        self.assertEqual(runtime.load(self.compose)['services']['page']['image'], 'page:new')
        current = self.compose.read_text()
        def next_command(base, *args, **kwargs):
            if '--format' in args:
                return current
            return ''
        with patch.object(pages, 'command', side_effect=next_command), patch.object(pages, 'inspect', return_value={'State': {'Running': True}}), patch.object(pages, 'ready', side_effect=ValueError('unhealthy')):
            with self.assertRaises(ValueError):
                pages.upgrade(self.root, self.id, 'page:broken', '1.2.93', 'v1.2.93')
        self.assertEqual(runtime.load(self.compose)['services']['page']['image'], 'page:new')

    def test_late_failure_restores_registry_and_legacy_compose_path(self):
        legacy = self.directory / 'compose.json'
        self.compose.rename(legacy)
        self.item['composeFiles'] = [str(legacy)]
        record = self.root / 'registry/subscription-pages' / (self.id + '.json')
        runtime.write(record, self.item)
        before = legacy.read_text()
        def command(base, *args, **kwargs):
            return before if '--format' in args else ''
        with patch.object(pages, 'command', side_effect=command), patch.object(pages, 'inspect', return_value={'State': {'Running': True}}), patch.object(pages, 'ready'), patch.object(pages.runtime, 'write_layout', side_effect=OSError('read only index')):
            with self.assertRaises(OSError):
                pages.upgrade(self.root, self.id, 'page:changed', '1.1.7.58', 'v1.2.93')
        self.assertEqual(runtime.load(record), self.item)
        self.assertEqual(legacy.read_text(), before)
        self.assertFalse(self.compose.exists())


if __name__ == '__main__':
    unittest.main()
