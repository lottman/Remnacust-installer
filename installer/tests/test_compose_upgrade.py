import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class ComposeUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.deployment = self.root/'deployment'
        self.backup = self.root/'backup'
        self.deployment.mkdir(); self.backup.mkdir()
        self.state = self.root/'state.json'
        self.candidate = self.root/'candidate.json'

    def setup_config(self, files, component='node', entry=None):
        before = {'directory': str(self.deployment), 'project': 'audit', 'component': component,
                  'composeFiles': [str(path) for path in files], 'applications': ['app']}
        if entry:
            before['composeEntryPoint'] = str(entry)
        runtime.write(self.backup/'state.before.json', before)
        state = copy.deepcopy(before); state['composeFiles'] = [str(self.candidate)]
        runtime.write(self.state, state)
        desired = {'name': 'audit', 'services': {'app': {'image': 'new@sha256:'+'a'*64,
                   'environment': {'SECRET_KEY': '${UNCHANGED}', 'NODE_PORT': '72'},
                   'network_mode': 'host', 'volumes': ['/logs:/logs']},
                   'db': {'image': 'postgres:18.4', 'volumes': ['database:/var/lib/postgresql']}},
                   'volumes': {'database': {'name': 'audit_database'}}, 'networks': {'default': {'name': 'audit_default'}}}
        runtime.write(self.candidate, desired)
        return desired

    def commit(self):
        runtime.commit_compose(self.state, self.candidate, self.backup, '1.1.9', 'v1.2.47')

    def test_original_yaml_is_updated_and_byte_exact_rollback_preserves_comments(self):
        main = self.deployment/'docker-compose.yml'
        original = b'# operator comment\r\nservices:\r\n  app:\r\n    image: old\r\n'
        main.write_bytes(original)
        expected = self.setup_config([main])
        self.commit()
        actual = runtime.load(main)
        self.assertEqual(actual.pop('x-remnacust-release')['version'], '1.1.9')
        self.assertEqual(actual, expected)
        self.assertEqual(runtime.load(self.state)['composeFiles'], [str(main)])
        self.assertEqual(os.stat(main).st_mode & 0o777, 0o600)
        runtime.restore_compose(self.backup)
        self.assertEqual(main.read_bytes(), original)

    def test_all_active_layers_are_consolidated_and_restore_exactly(self):
        main = self.deployment/'compose.yaml'; overlay = self.deployment/'compose.override.yaml'
        originals = ['services: {app: {image: old}}\n', 'services: {app: {ports: ["7070:7070"]}}\n']
        for path, content in zip([main, overlay], originals): path.write_text(content)
        expected = self.setup_config([main, overlay], 'panel')
        expected['services']['app']['ports'] = ['7070:7070']; runtime.write(self.candidate, expected)
        self.commit()
        self.assertEqual(runtime.load(overlay), {'services': {}})
        actual = runtime.load(main); actual.pop('x-remnacust-release')
        self.assertEqual(actual, expected)
        runtime.restore_compose(self.backup)
        self.assertEqual([main.read_text(), overlay.read_text()], originals)

    def test_legacy_shadow_config_updates_original_entry_point(self):
        main = self.deployment/'compose.json'; shadow = self.deployment/'compose.remnacust-20261010T120000Z-72.json'
        main.write_text('{"services":{"app":{"image":"ancient"}}}'); shadow.write_text('{"services":{"app":{"image":"old"}}}')
        original = main.read_bytes()
        self.setup_config([shadow])
        self.commit()
        canonical = self.deployment/'docker-compose.yml'
        self.assertEqual(runtime.load(canonical)['services']['app']['image'], 'new@sha256:'+'a'*64)
        self.assertEqual(runtime.load(self.state)['composeEntryPoint'], str(canonical))
        self.assertFalse(main.exists())
        self.assertFalse(shadow.exists())
        runtime.restore_compose(self.backup)
        self.assertEqual(main.read_bytes(), original)
        self.assertEqual(runtime.load(shadow)['services']['app']['image'], 'old')

    def test_legacy_missing_entry_point_is_created_and_removed_on_rollback(self):
        shadow = self.deployment/'compose.remnacust-20261010T120000Z-72.json'; shadow.write_text('{}')
        self.setup_config([shadow]); self.commit()
        main = self.deployment/'docker-compose.yml'
        self.assertTrue(main.exists())
        runtime.restore_compose(self.backup)
        self.assertFalse(main.exists())

    def test_partial_write_failure_restores_original_files_and_state(self):
        main = self.deployment/'compose.yaml'; layer = self.deployment/'override.yml'
        main.write_text('original'); layer.write_text('layer')
        self.setup_config([main, layer]); original_state = self.state.read_bytes()
        real_write = runtime.write
        failed = False
        def interrupted(path, value, mode=0o600):
            nonlocal failed
            if Path(path) == layer and value == {'services': {}} and not failed:
                failed = True
                raise OSError('simulated write failure')
            return real_write(path, value, mode)
        with patch.object(runtime, 'write', interrupted), self.assertRaises(OSError): self.commit()
        self.assertEqual(main.read_text(), 'original'); self.assertEqual(layer.read_text(), 'layer')
        self.assertEqual(self.state.read_bytes(), original_state)

    def test_outside_project_and_symlinks_are_rejected_before_changes(self):
        outside = self.root/'foreign.yml'; outside.write_text('foreign')
        self.setup_config([outside])
        with self.assertRaises(runtime.ConfigurationError): self.commit()
        self.assertEqual(outside.read_text(), 'foreign')
        link = self.deployment/'compose.yaml'
        try: link.symlink_to(outside)
        except OSError: self.skipTest('Creating symlinks unavailable on this OS')
        self.setup_config([link])
        with self.assertRaises(runtime.ConfigurationError): self.commit()
        self.assertEqual(outside.read_text(), 'foreign')

    def test_inactive_auto_override_is_rejected_without_overwriting_it(self):
        main = self.deployment/'compose.yaml'; main.write_text('main')
        overlay = self.deployment/'compose.override.yaml'; overlay.write_text('unselected')
        self.setup_config([main])
        with self.assertRaises(runtime.ConfigurationError): self.commit()
        self.assertEqual(main.read_text(), 'main'); self.assertEqual(overlay.read_text(), 'unselected')

    def test_next_update_accepts_empty_layer_left_by_previous_consolidation(self):
        main = self.deployment/'compose.json'; main.write_text('original')
        overlay = self.deployment/'compose.override.yaml'
        runtime.write(overlay, {'services': {}})
        self.setup_config([main], 'panel')
        self.commit()
        self.assertEqual(runtime.load(self.deployment/'docker-compose.yml')['services']['app']['image'], 'new@sha256:'+'a'*64)
        self.assertEqual(runtime.load(overlay), {'services': {}})
        runtime.restore_compose(self.backup)
        self.assertEqual(main.read_text(), 'original')
        self.assertEqual(runtime.load(overlay), {'services': {}})

    def test_tampered_snapshot_does_not_restore_any_files(self):
        main = self.deployment/'compose.json'; main.write_text('original')
        self.setup_config([main]); self.commit()
        canonical = self.deployment/'docker-compose.yml'
        after = canonical.read_bytes()
        original = next(item for item in runtime.load(self.backup/'compose-files.before.json')['files'] if item['existed'])
        (self.backup/original['backup']).write_text('tampered')
        with self.assertRaises(runtime.ConfigurationError): runtime.restore_compose(self.backup)
        self.assertEqual(canonical.read_bytes(), after)

    def test_real_compose_config_preserves_merged_settings_and_updates_all_app_roles(self):
        if not os.environ.get('REMNACUST_TEST_REAL_COMPOSE'):
            self.skipTest('Set REMNACUST_TEST_REAL_COMPOSE=1 to exercise real Compose v2')
        main = self.deployment/'docker-compose.yml'; layer = self.deployment/'docker-compose.override.yml'
        main.write_text('services:\n  app:\n    image: old-panel\n    ports: ["127.0.0.1:7070:3000"]\n    environment:\n      APP_SECRET: "${KEEP_LITERAL:-example}"\n    volumes: ["data:/data"]\n  jobs:\n    image: old-panel\n    environment: {INSTANCE_TYPE: processor}\n  db:\n    image: postgres:18.4\n    volumes: ["database:/var/lib/postgresql"]\nvolumes: {data: {}, database: {}}\n')
        layer.write_text('services:\n  app:\n    mem_limit: 768m\n    restart: always\n')
        def config(files):
            command = ['docker', 'compose', '--project-name', 'audit', '--project-directory', str(self.deployment)]
            for filename in files: command.extend(['-f', str(filename)])
            command.extend(['config', '--no-interpolate', '--no-env-resolution', '--format', 'json'])
            return json.loads(subprocess.check_output(command, text=True))
        original = config([main, layer])
        live = {'Config': {'Labels': {'com.docker.compose.service': 'app'}}}
        desired, apps = runtime.transform(original, live, 'panel', 'new-panel@sha256:'+'a'*64)
        self.setup_config([main, layer], 'panel')
        state = runtime.load(self.state); state['applications'] = apps; runtime.write(self.state, state)
        runtime.write(self.candidate, desired)
        self.commit()
        actual = config([main, layer]); actual.pop('x-remnacust-release', None)
        self.assertEqual(actual, desired)
        self.assertEqual(actual['services']['jobs']['image'], desired['services']['app']['image'])
        self.assertEqual(actual['services']['db'], original['services']['db'])
        runtime.restore_compose(self.backup)
        self.assertEqual(config([main, layer]), original)


if __name__ == '__main__': unittest.main()
