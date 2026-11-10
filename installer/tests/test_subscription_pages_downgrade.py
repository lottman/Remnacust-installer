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


class PageDowngradeTests(unittest.TestCase):
    repository = 'ghcr.io/lottman/remnacust-subscription-page'
    version = '1.1.7.100'
    release = 'v1.2.148'

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        environment = patch.dict(os.environ, REMNACUST_ROOT=str(self.root))
        environment.start()
        self.addCleanup(environment.stop)
        self.directory = self.root / 'page'
        self.directory.mkdir()
        self.env = self.directory / '.env'
        runtime.write(self.env, 'REMNAWAVE_PANEL_URL=https://old.example.test\n'
                      'REMNAWAVE_API_TOKEN=old.valid.token\nKEEP=unchanged\n')
        self.compose = self.directory / 'docker-compose.yml'
        self.config = {'services': {
            'page': {'image': self.image(), 'env_file': [str(self.env)]},
            'database': {'image': 'postgres:18.3'},
        }}
        self.item = {'directory': str(self.directory), 'project': 'fixture-page',
                     'service': 'page', 'composeFiles': [str(self.compose)],
                     'domain': 'subscription.example.test'}
        self.page = pages.identity(self.item)
        self.record = self.root / 'registry/subscription-pages' / (self.page + '.json')
        self.persist()
        self.current = self.container()
        self.commands = []

    def image(self, version=None, release=None):
        return self.repository + ':' + (version or self.version) + '-' + (release or self.release) + '-amd64'

    def container(self, version=None, running=False):
        return {'State': {'Running': running}, 'Config': {
            'Image': self.config['services']['page']['image'],
            'Labels': {'org.opencontainers.image.version': version or self.version,
                       'com.docker.compose.project': self.item['project'],
                       'com.docker.compose.service': self.item['service']},
        }}

    def persist(self):
        runtime.write(self.compose, self.config)
        runtime.write(self.record, self.item)

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob('*') if path.is_file()}

    def command(self, base, *args):
        self.commands.append([*base, *args])
        if '--format' in args:
            return json.dumps(self.config)
        if args == ('--profile', '*', 'config', '--quiet'):
            return ''
        if args[:1] == ('up',) and args[-1] == 'page' and '--no-deps' in args:
            return ''
        raise AssertionError('Unexpected command: ' + repr([*base, *args]))

    def assert_blocked(self, version=None, release=None):
        version = version or self.version
        release = release or self.release
        original = self.snapshot()
        with patch.object(pages, 'command', side_effect=self.command), \
                patch.object(pages, 'inspect', return_value=self.current), \
                patch.object(runtime, 'write') as write, \
                patch.object(runtime, 'commit_compose') as commit, \
                patch.object(runtime, 'write_layout') as layout, \
                patch.object(pages.connection, 'resolve') as resolve, \
                patch.object(pages.connection, 'probe') as probe, \
                patch.object(pages.connection, 'edit') as edit, \
                patch.object(pages.connection, 'write_edits') as write_edits, \
                self.assertRaisesRegex(runtime.ConfigurationError, 'Понижение.*запрещено') as error:
            pages.upgrade(self.root, self.page, self.image(version, release), version, release)
        self.assertRegex(str(error.exception), r'\d+\.\d+')
        for mutation in (write, commit, layout, resolve, probe, edit, write_edits):
            mutation.assert_not_called()
        self.assertEqual(self.snapshot(), original)
        self.assertFalse((self.root / 'backups').exists())
        self.assertEqual(len(self.commands), 1)
        self.assertIn('--format', self.commands[0])
        self.commands.clear()

    def run_upgrade(self, version=None, release=None):
        version = version or self.version
        release = release or self.release
        with patch.object(pages, 'command', side_effect=self.command), \
                patch.object(pages, 'inspect', return_value=self.current), \
                patch.object(pages, 'ready') as ready, \
                patch.object(pages.connection, 'probe') as probe:
            pages.upgrade(self.root, self.page, self.image(version, release), version, release)
        probe.assert_not_called()
        ready.assert_not_called()
        updated = runtime.load(self.compose)
        self.assertEqual(updated['services']['page']['image'], self.image(version, release))
        self.assertEqual(updated['services']['database'], self.config['services']['database'])
        self.assertTrue(any('--no-start' in command for command in self.commands))
        return updated

    def test_component_label_blocks_downgrade_for_running_and_stopped_pages(self):
        self.config['services']['page']['image'] = self.repository + ':latest'
        self.persist()
        for running in (True, False):
            with self.subTest(running=running):
                self.current = self.container('1.1.7.101', running=running)
                self.assert_blocked()

    def test_older_installer_is_blocked_for_same_component_version(self):
        self.config['services']['page']['image'] = self.repository + ':latest'
        for component in ('subscription-page', 'panel'):
            with self.subTest(marker_component=component):
                self.config['x-remnacust-release'] = {
                    'component': component, 'version': self.version, 'installer': self.release}
                self.persist()
                self.assert_blocked(release='v1.2.147')

    def test_missing_container_uses_component_version_from_compose_pin(self):
        self.current = None
        for pin in (self.image('1.1.7.101'), self.repository + ':1.1.7.101'):
            with self.subTest(pin=pin):
                self.config['services']['page']['image'] = pin
                self.persist()
                self.assert_blocked()

    def test_missing_container_uses_installer_version_from_compose_pin(self):
        self.current = None
        self.assert_blocked(release='v1.2.147')

    def test_missing_container_and_unversioned_pin_use_matching_release_marker(self):
        self.current = None
        self.config['services']['page']['image'] = self.repository + ':latest'
        self.config['x-remnacust-release'] = {
            'component': 'subscription-page', 'version': '1.1.7.101', 'installer': self.release}
        self.persist()
        self.assert_blocked()

    def test_equal_component_and_installer_versions_allow_reinstall(self):
        original_env = self.env.read_bytes()
        updated = self.run_upgrade()
        self.assertEqual(updated['x-remnacust-release'], {
            'component': 'subscription-page', 'version': self.version, 'installer': self.release})
        self.assertEqual(self.env.read_bytes(), original_env)

    def test_unknown_upstream_migration_does_not_compare_unrelated_version_families(self):
        self.config['services']['page']['image'] = 'ghcr.io/remnawave/subscription-page:3.2.0'
        self.config['x-remnacust-release'] = {
            'component': 'panel', 'version': '9.9.9', 'installer': self.release}
        self.item.update(image=self.config['services']['page']['image'], version='3.2.0')
        self.persist()
        self.current = self.container('3.2.0')
        self.run_upgrade()

    def test_unknown_legacy_version_remains_migratable(self):
        self.config['services']['page']['image'] = self.repository + ':legacy'
        self.persist()
        self.current = None
        self.run_upgrade()

    def test_configure_bypasses_version_guard_and_preserves_image_and_release(self):
        self.config['x-remnacust-release'] = {
            'component': 'subscription-page', 'version': '1.1.7.101', 'installer': 'v1.2.149'}
        self.persist()
        original = copy.deepcopy(self.config)
        with patch.object(pages, 'command', side_effect=self.command) as command, \
                patch.object(pages, 'inspect', return_value=self.current), \
                patch.object(runtime, 'assert_upgrade_versions', side_effect=AssertionError('configure must bypass version checks')) as guard, \
                patch.object(pages.connection, 'probe') as probe, \
                patch.object(pages, 'ready') as ready:
            pages.configure(self.root, self.page, 'https://new.example.test', 'new.valid.token')
        guard.assert_not_called()
        ready.assert_not_called()
        probe.assert_called_once_with(self.current['Config']['Image'], 'https://new.example.test',
                                      'new.valid.token', None, self.current, command)
        self.assertEqual(runtime.load(self.compose), original)
        self.assertIn('REMNAWAVE_PANEL_URL=https://new.example.test', self.env.read_text())
        self.assertIn('REMNAWAVE_API_TOKEN=new.valid.token', self.env.read_text())
        self.assertIn('KEEP=unchanged', self.env.read_text())
        self.assertTrue(any('--no-start' in command for command in self.commands))


if __name__ == '__main__':
    unittest.main()
