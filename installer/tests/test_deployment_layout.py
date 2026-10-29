import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deployment_layout as layout
import runtime


class CanonicalLayoutTests(unittest.TestCase):
    def test_only_paths_change_not_credentials_or_named_resources(self):
        old, new = Path('/opt/remnacust/panel-20261007093515-240659'), Path('/opt/remnacust/panel')
        before = {'services': {'api': {'image': 'panel:fixed', 'environment': {'APP_SECRET': 'unchanged'}, 'env_file': [{'path': str(old / '.env')}], 'volumes': [{'type': 'bind', 'source': str(old / 'certs'), 'target': '/certs'}, {'type': 'volume', 'source': 'database', 'target': '/data'}]}}, 'volumes': {'database': {'name': 'original-database'}}}
        after = layout.compose_paths(before, old, new)
        self.assertEqual(after['services']['api']['environment'], before['services']['api']['environment'])
        self.assertEqual(after['volumes'], before['volumes'])
        self.assertEqual(after['services']['api']['env_file'][0]['path'], str(new / '.env'))
        self.assertEqual(after['services']['api']['volumes'][0]['source'], str(new / 'certs'))
        self.assertEqual(before['services']['api']['volumes'][0]['source'], str(old / 'certs'))

    def test_other_projects_and_stopped_containers_protect_referenced_paths(self):
        path = Path('/opt/remnacust/node')
        container = {'Config': {'Labels': {'com.docker.compose.project': 'shared-proxy'}}, 'Mounts': [{'Source': str(path / 'certs')}], 'State': {'Running': False}}
        self.assertTrue(layout.referenced(path, [container], 'node'))
        self.assertFalse(layout.referenced(Path('/opt/remnacust/node-other'), [container]))

    def test_only_known_unreferenced_old_directories_are_archived(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / 'panel-20261007093515-240659'; old.mkdir(); (old / '.env').write_text('secret=preserved')
            custom = root / 'panel-custom'; custom.mkdir()
            protected = root / 'panel-20261007125352-343161'; protected.mkdir()
            containers = [{'Config': {'Labels': {'com.docker.compose.project.working_dir': str(protected)}}}]
            layout.archive_unused(root, 'panel', containers)
            self.assertTrue(custom.exists())
            self.assertTrue(protected.exists())
            self.assertFalse(old.exists())
            self.assertEqual((root / 'backups/retired-layout' / old.name / '.env').read_text(), 'secret=preserved')

    def test_custom_deployments_are_not_silently_moved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); custom = root / 'operator-custom'; custom.mkdir()
            state = {'component': 'node', 'directory': str(custom)}
            runtime.write(root / 'registry/node.json', state)
            with patch.object(layout, 'inventory', return_value=[]):
                self.assertEqual(layout.normalize(root, 'node'), state)
            self.assertTrue(custom.is_dir())


class ConfigArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.directory = self.root / 'panel'
        self.directory.mkdir()
        self.main = self.directory / 'docker-compose.yml'
        self.main.write_text('{"services":{"app":{"image":"fixture"}}}')
        self.state = {'component': 'panel', 'directory': str(self.directory),
                      'project': 'fixture', 'composeFiles': [str(self.main)]}
        runtime.write(self.root / 'registry/panel.json', self.state)
        self.config = {'services': {'app': {'image': 'fixture'}}}
        self.command = patch.object(layout, 'command', side_effect=lambda *args: json.dumps(self.config))
        self.command.start()
        self.addCleanup(self.command.stop)

    def old(self, number=1):
        path = self.directory / ('compose.remnacust-20261010T120000Z-' + str(number) + '.json')
        path.write_text('private-original-' + str(number))
        return path

    def test_copies_move_once_with_manifest_while_working_files_remain(self):
        copies = [self.old(), self.old(2), self.directory / 'Caddyfile.before-first-vpn']
        copies[-1].write_text('original proxy')
        env = self.directory / '.env'; env.write_text('SECRET=preserve')
        custom = self.directory / 'operator-backup.json'; custom.write_text('keep')
        originals = {path.name: path.read_bytes() for path in copies}
        archive = layout.archive_configs(self.root, self.state, [])
        self.assertEqual(archive.parent, self.root / 'backups/panel')
        manifest = runtime.load(archive / 'manifest.json')
        self.assertEqual(len(manifest['files']), 3)
        for path in copies:
            self.assertFalse(path.exists())
            self.assertEqual((archive / path.name).read_bytes(), originals[path.name])
        self.assertTrue(self.main.exists()); self.assertTrue(custom.exists())
        self.assertEqual(env.read_text(), 'SECRET=preserve')
        self.assertIsNone(layout.archive_configs(self.root, self.state, []))
        self.assertEqual(len(list(archive.parent.iterdir())), 1)
        if os.name != 'nt':
            self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
            self.assertEqual((archive / 'manifest.json').stat().st_mode & 0o777, 0o600)

    def test_active_registered_and_stopped_container_files_are_preserved(self):
        registered, labelled, mounted, stale = [self.old(i) for i in range(1, 5)]
        runtime.write(self.root / 'registry/node.json', {**self.state, 'composeFiles': [str(registered)]})
        containers = [{'State': {'Running': False}, 'Config': {'Labels': {
            'com.docker.compose.project.config_files': str(labelled)}}, 'Mounts': [{'Source': str(mounted)}]}]
        layout.archive_configs(self.root, self.state, containers)
        self.assertTrue(all(path.exists() for path in (registered, labelled, mounted)))
        self.assertFalse(stale.exists())

    def test_compose_references_and_proxy_imports_are_preserved(self):
        env, bind, secret, proxy, stale = [self.old(i) for i in range(1, 6)]
        self.config = {'services': {'off': {'profiles': ['off'], 'env_file': [str(env)],
            'volumes': [{'type': 'bind', 'source': str(bind), 'target': '/file'}]}},
            'secrets': {'token': {'file': str(secret)}}}
        (self.directory / 'Caddyfile').write_text('import ' + proxy.name)
        layout.archive_configs(self.root, self.state, [])
        self.assertTrue(all(path.exists() for path in (env, bind, secret, proxy)))
        self.assertFalse(stale.exists())

    def test_invalid_compose_and_failed_inventory_do_not_move_anything(self):
        stale = self.old()
        with patch.object(layout, 'command', return_value='not json'), self.assertRaises(ValueError):
            layout.archive_configs(self.root, self.state, [])
        with patch.object(layout, 'inventory', side_effect=ValueError('docker unavailable')), self.assertRaises(ValueError):
            layout.archive_configs(self.root, self.state)
        self.assertTrue(stale.exists())

    def test_source_extends_wildcard_imports_and_directory_mounts_are_preserved(self):
        source, wildcard = self.old(), self.old(2)
        self.main.write_text('services:\n  app:\n    extends:\n      file: ' + source.name)
        (self.directory / 'Caddyfile').write_text('import compose.remnacust-*-2.json')
        self.assertIsNone(layout.archive_configs(self.root, self.state, []))
        (self.directory / 'Caddyfile').unlink()
        self.main.write_text('{}')
        self.config = {'services': {'app': {'volumes': [{'type': 'bind', 'source': str(self.directory), 'target': '/all'}]}}}
        self.assertIsNone(layout.archive_configs(self.root, self.state, []))
        self.config = {'services': {}}
        container = {'Mounts': [{'Type': 'bind', 'Source': str(self.directory)}]}
        self.assertIsNone(layout.archive_configs(self.root, self.state, [container]))
        self.assertTrue(source.exists()); self.assertTrue(wildcard.exists())

    def test_symlinks_are_never_followed(self):
        outside = self.root / 'outside'; outside.mkdir()
        link = self.directory / 'compose.remnacust-20261010T120000Z-1.json'
        link.symlink_to(self.main)
        self.assertIsNone(layout.archive_configs(self.root, self.state, []))
        link.unlink(); stale = self.old()
        (self.root / 'backups').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            layout.archive_configs(self.root, self.state, [])
        self.assertTrue(stale.exists()); self.assertEqual(list(outside.iterdir()), [])

    def test_partial_move_failure_restores_files(self):
        first, second = self.old(), self.old(2)
        rename = Path.rename
        def interrupted(path, target):
            if path == second:
                raise OSError('disk failure')
            return rename(path, target)
        with patch.object(Path, 'rename', interrupted), self.assertRaises(OSError):
            layout.archive_configs(self.root, self.state, [])
        self.assertTrue(first.exists()); self.assertTrue(second.exists())

    def test_failed_move_does_not_overwrite_a_new_operator_file(self):
        first, second = self.old(), self.old(2)
        rename = Path.rename
        def interrupted(path, target):
            if path == second:
                first.write_text('operator replacement')
                raise OSError('disk failure')
            return rename(path, target)
        with patch.object(Path, 'rename', interrupted), self.assertRaises(OSError):
            layout.archive_configs(self.root, self.state, [])
        self.assertEqual(first.read_text(), 'operator replacement')
        archive = next((self.root / 'backups/panel').glob('legacy-config-*'))
        self.assertEqual((archive / first.name).read_text(), 'private-original-1')
        self.assertTrue(second.exists())

    def test_cleanup_handles_every_registered_component_and_page(self):
        self.old()
        for component in ('node', 'subscription-page'):
            directory = self.root / component; directory.mkdir()
            main = directory / 'docker-compose.yml'; main.write_text('{}')
            old = directory / 'compose.remnacust-20261010T120000Z-1.json'; old.write_text('copy')
            item = {**self.state, 'component': component, 'directory': str(directory), 'composeFiles': [str(main)]}
            if component == 'subscription-page':
                from subscription_pages import identity
                item['service'] = 'page'
                record = self.root / 'registry/subscription-pages' / (identity(item) + '.json')
            else:
                record = self.root / 'registry/node.json'
            runtime.write(record, item)
        with patch.object(layout, 'inventory', return_value=[]):
            layout.cleanup_registered(self.root)
        for component in ('panel', 'node', 'subscription-page'):
            self.assertEqual(len(list((self.root / 'backups' / component).glob('legacy-config-*'))), 1)
            self.assertTrue((self.root / component / 'docker-compose.yml').exists())


if __name__ == '__main__':
    unittest.main()
