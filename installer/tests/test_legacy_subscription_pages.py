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


class LegacyPagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root, self.legacy = base / 'remnacust', base / 'remnawave'
        self.legacy.mkdir()
        compose = self.legacy / 'docker-compose.yml'
        compose.write_text('{"services":{"page":{"image":"remnawave/subscription-page:old"}}}')
        runtime.write(self.root / 'registry/panel.json', {'component': 'panel'})
        self.panel = {'Config': {'Env': ['FRONT_END_DOMAIN=panel.example.test'], 'Labels': {'com.docker.compose.service': 'remnawave'}},
                      'NetworkSettings': {'Networks': {'private': {}}}}
        self.container = {'Id': 'a' * 64, 'Config': {
            'Image': 'remnawave/subscription-page:old',
            'Env': ['REMNAWAVE_PANEL_URL=http://remnawave:3000', 'REMNAWAVE_API_TOKEN=private-token'],
            'Labels': {'com.docker.compose.project': 'old-page', 'com.docker.compose.service': 'page',
                       'com.docker.compose.project.working_dir': str(self.legacy),
                       'com.docker.compose.project.config_files': str(compose)}},
            'NetworkSettings': {'Networks': {'private': {}}}, 'State': {'Running': True}}
        self.calls = []

    def command(self, base, *args):
        self.calls.append([*base, *args])
        if [*base, *args] == ['docker', 'ps', '--all', '--quiet']:
            return self.container['Id']
        if [*base, *args][:2] == ['docker', 'inspect']:
            return json.dumps([self.container])
        if args and args[0] in {'start', 'stop', 'restart'}:
            return ''
        raise AssertionError('Unexpected Docker mutation: ' + str([*base, *args]))

    def mocks(self):
        return patch.object(pages, 'command', side_effect=self.command)

    def test_legacy_page_is_visible_without_registration_or_secret_disclosure(self):
        before = (self.legacy / 'docker-compose.yml').read_bytes()
        with self.mocks(), patch.object(pages, 'inspect', side_effect=lambda item: self.panel if item.get('service') == 'remnawave' else self.container):
            listed = pages.listing(self.root)
        self.assertEqual(len(listed), 1)
        self.assertFalse(listed[0]['managed'])
        self.assertTrue(listed[0]['running'])
        self.assertNotIn('private-token', json.dumps(listed))
        self.assertFalse((self.root / 'registry/subscription-pages').exists())
        self.assertEqual(before, (self.legacy / 'docker-compose.yml').read_bytes())

    def test_existing_page_can_restart_but_cannot_implicitly_upgrade_or_uninstall(self):
        with self.mocks(), patch.object(pages, 'inspect', return_value=self.panel), patch.object(pages, 'ready'):
            page = next(iter(pages.discovered(self.root)))
            pages.service(self.root, page, 'restart')
            with self.assertRaisesRegex(ValueError, 'PAGE_NOT_REGISTERED'):
                pages.upgrade(self.root, page, 'our-image', '1.1.7.70', 'v1.2.106')
            with self.assertRaisesRegex(ValueError, 'PAGE_NOT_REGISTERED'):
                pages.uninstall(self.root, page)
        commands = [x for x in self.calls if x[:2] == ['docker', 'compose']]
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][-3:], ['restart', '--no-deps', 'page'])

    def test_foreign_panel_network_image_or_missing_files_are_not_manageable(self):
        original = copy.deepcopy(self.container)
        cases = [lambda c: c['Config'].update(Image='evil.example/subscription-page:old'),
                 lambda c: c['NetworkSettings'].update(Networks={'foreign': {}}),
                 lambda c: c['Config'].update(Env=['REMNAWAVE_PANEL_URL=https://foreign.example.test']),
                 lambda c: c['Config']['Labels'].update({'com.docker.compose.project.config_files': str(self.legacy / 'missing.yml')})]
        for change in cases:
            self.container = copy.deepcopy(original)
            change(self.container)
            with self.subTest(image=self.container['Config']['Image']), self.mocks(), patch.object(pages, 'inspect', return_value=self.panel):
                self.assertEqual(pages.discovered(self.root), {})

    @unittest.skipIf(os.name == 'nt', 'POSIX ownership/mode check')
    def test_world_writable_compose_is_not_accepted(self):
        compose = self.legacy / 'docker-compose.yml'
        compose.chmod(0o666)
        with self.mocks(), patch.object(pages, 'inspect', return_value=self.panel):
            self.assertEqual(pages.discovered(self.root), {})

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink/mode check')
    def test_unsafe_nested_compose_directory_is_not_accepted(self):
        nested = self.legacy / 'config'
        nested.mkdir()
        compose = nested / 'compose.yml'
        compose.write_text('{"services":{}}')
        self.container['Config']['Labels']['com.docker.compose.project.config_files'] = str(compose)
        nested.chmod(0o777)
        with self.mocks(), patch.object(pages, 'inspect', return_value=self.panel):
            self.assertEqual(pages.discovered(self.root), {})

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink/mode check')
    def test_symlinked_compose_parent_is_not_accepted(self):
        nested = self.legacy / 'config'
        nested.mkdir()
        (nested / 'compose.yml').write_text('{"services":{}}')
        link = self.legacy / 'linked'
        link.symlink_to(nested, target_is_directory=True)
        self.container['Config']['Labels']['com.docker.compose.project.config_files'] = str(link / 'compose.yml')
        with self.mocks(), patch.object(pages, 'inspect', return_value=self.panel):
            self.assertEqual(pages.discovered(self.root), {})


if __name__ == '__main__':
    unittest.main()
