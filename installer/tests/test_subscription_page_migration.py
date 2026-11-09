import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import subscription_pages as pages


class PageMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / 'legacy-page'
        self.directory.mkdir()
        self.compose = self.directory / 'docker-compose.yml'
        self.config = {'services': {
            'page': {'image': 'remnawave/subscription-page:3.4.8', 'environment': {
                'REMNAWAVE_PANEL_URL': 'https://panel.example.test', 'REMNAWAVE_API_TOKEN': 'fixture.private.token'},
                'ports': ['127.0.0.1:3010:3010'], 'volumes': ['./custom.json:/app/custom.json:ro']},
            'proxy': {'image': 'caddy:2.9', 'environment': {'UNCHANGED': 'yes'}}}}
        runtime.write(self.compose, self.config)
        self.env = self.directory / '.env'; self.env.write_text('EXISTING=retained\n')
        self.custom = self.directory / 'custom.json'; self.custom.write_text('{"theme":"retained"}')
        self.current = {'Id': 'a' * 64, 'Name': '/legacy-page-1', 'State': {'Running': True},
                        'Config': {'Image': 'remnawave/subscription-page:3.4.8', 'Env': ['REMNAWAVE_PANEL_URL=https://panel.example.test', 'REMNAWAVE_API_TOKEN=fixture.private.token'], 'Labels': {
                            'org.opencontainers.image.version': '3.4.8',
                            'com.docker.compose.project': 'legacy', 'com.docker.compose.service': 'page',
                            'com.docker.compose.project.working_dir': str(self.directory),
                            'com.docker.compose.project.config_files': str(self.compose)}}}
        self.calls = []
        previous = os.environ.get('REMNACUST_ROOT')
        os.environ['REMNACUST_ROOT'] = str(self.root)
        self.addCleanup(lambda: os.environ.pop('REMNACUST_ROOT', None) if previous is None else os.environ.__setitem__('REMNACUST_ROOT', previous))

    def command(self, base, *args, **kwargs):
        self.calls.append([*base, *args])
        if base == ['docker'] and args[0] == 'ps': return self.current['Id']
        if base == ['docker'] and args[0] == 'inspect': return json.dumps([self.current])
        if '--format' in args: return json.dumps(self.config)
        return ''

    def test_discovery_without_local_panel_returns_only_safe_identity(self):
        with patch.object(pages, 'command', side_effect=self.command):
            choices = pages.migration_candidates(self.root)
        self.assertEqual(len(choices), 1)
        self.assertEqual(choices[0]['container'], self.current['Id'])
        self.assertNotIn('fixture.private.token', json.dumps(choices))
        self.assertFalse((self.root / 'registry').exists())

    def test_explicit_source_filters_do_not_choose_another_page(self):
        with patch.object(pages, 'command', side_effect=self.command):
            self.assertEqual(pages.migration_candidates(self.root, 'other-page'), [])
            self.assertEqual(pages.migration_candidates(self.root, directory=str(self.root / 'other')), [])
            self.assertEqual(len(pages.migration_candidates(self.root, 'legacy-page-1')), 1)
        with patch.object(pages, 'command') as command:
            with self.assertRaises(ValueError): pages.migration_candidates(self.root, '--privileged')
            command.assert_not_called()

    def test_unknown_and_custom_images_cannot_bypass_downgrade_guard(self):
        for image, error in [('evil.test/subscription-page:3.4.8', 'PAGE_MIGRATION_SOURCE'), ('ghcr.io/lottman/remnacust-subscription-page:9.9.9', 'PAGE_DOWNGRADE_BLOCKED')]:
            self.current['Config']['Image'] = image
            with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current):
                with self.assertRaisesRegex(ValueError, error):
                    pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152')
            self.assertEqual(runtime.load(self.compose), self.config)
            self.assertFalse((self.root / 'registry').exists())

    def test_migration_keeps_credentials_files_proxy_ports_and_mounts(self):
        before = copy.deepcopy(self.config)
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), patch.object(pages, 'ready'):
            page = pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152')
        after = runtime.load(self.compose)
        self.assertEqual(after['services']['proxy'], before['services']['proxy'])
        expected = before['services']['page']; expected['image'] = 'page:new'
        self.assertEqual(after['services']['page'], expected)
        self.assertEqual(self.env.read_text(), 'EXISTING=retained\n')
        self.assertEqual(self.custom.read_text(), '{"theme":"retained"}')
        self.assertIn(page, pages.records(self.root))
        self.assertTrue(any('up' in call and '--no-deps' in call and call[-1] == 'page' for call in self.calls))
        self.assertFalse(any('down' in call or 'rm' in call for call in self.calls))

    def test_unregistered_early_custom_digest_is_adopted_without_local_panel(self):
        self.current['Config']['Image'] = 'ghcr.io/lottman/remnacust-subscription-page@sha256:' + 'e' * 64
        self.current['Config']['Labels']['org.opencontainers.image.version'] = '1.1.7.4'
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), patch.object(pages, 'ready'):
            choice = pages.migration_candidates(self.root)[0]
            self.assertFalse(choice['needsConnection'])
            page = pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152')
        self.assertIn(page, pages.records(self.root))
        self.assertFalse((self.root / 'registry/panel.json').exists())
        self.assertEqual(runtime.load(self.compose)['services']['proxy'], self.config['services']['proxy'])

    def test_missing_connection_requires_wizard_input_before_any_write(self):
        self.current['Config']['Env'] = []
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current):
            self.assertTrue(pages.migration_candidates(self.root)[0]['needsConnection'])
            with self.assertRaisesRegex(ValueError, 'PAGE_CONNECTION_REQUIRED'):
                pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152')
        self.assertFalse((self.root / 'backups').exists())
        self.assertEqual(runtime.load(self.compose), self.config)

    def test_missing_connection_is_probed_and_updated_together_with_image(self):
        self.current['Config']['Env'] = []
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), patch.object(pages, 'ready'), patch.object(pages.connection, 'probe') as probe:
            pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152', panel_connection=('https://new-panel.example.test', 'fixture.new.token'))
        probe.assert_called_once()
        after = runtime.load(self.compose)
        self.assertEqual(after['services']['page']['image'], 'page:new')
        self.assertEqual(after['services']['page']['environment']['REMNAWAVE_PANEL_URL'], 'https://new-panel.example.test')
        self.assertEqual(after['x-remnacust-release']['version'], '1.1.7.106')
        self.assertEqual(after['services']['proxy'], self.config['services']['proxy'])

    def test_stopped_page_is_not_started(self):
        self.current['State']['Running'] = False
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), patch.object(pages, 'ready') as ready:
            pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152')
        ready.assert_not_called()
        self.assertTrue(any('up' in call and '--no-start' in call for call in self.calls))

    def test_health_failure_restores_compose_and_creates_no_record(self):
        original = self.compose.read_bytes()
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), patch.object(pages, 'ready', side_effect=ValueError('fixture health failed')):
            with self.assertRaisesRegex(ValueError, 'fixture health failed'):
                pages.migrate(self.root, self.current['Id'], 'page:broken', '1.1.7.106', 'v1.2.152')
        self.assertEqual(self.compose.read_bytes(), original)
        self.assertEqual(pages.records(self.root), {})
        self.assertTrue(list((self.root / 'backups').glob('subscription-page-*')))

    def test_changed_container_identity_is_rejected_before_compose_mutation(self):
        changed = {**self.current, 'Id': 'b' * 64}
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=changed):
            with self.assertRaisesRegex(ValueError, 'PAGE_MIGRATION_SOURCE'):
                pages.migrate(self.root, self.current['Id'], 'page:new', '1.1.7.106', 'v1.2.152')
        self.assertEqual(runtime.load(self.compose), self.config)
        self.assertFalse((self.root / 'backups').exists())

    def test_symlink_and_writable_ancestor_are_not_migrated(self):
        if os.name == 'nt': self.skipTest('native filesystem ownership checks')
        self.directory.chmod(0o777)
        with patch.object(pages, 'command', side_effect=self.command):
            self.assertEqual(pages.migration_candidates(self.root), [])
        self.directory.chmod(0o700)
        self.compose.rename(self.directory / 'real.yml')
        self.compose.symlink_to(self.directory / 'real.yml')
        with patch.object(pages, 'command', side_effect=self.command):
            self.assertEqual(pages.migration_candidates(self.root), [])


if __name__ == '__main__':
    unittest.main()
