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
import subscription_migration as migration


def container(image='remnawave/subscription-page:old', panel='http://remnawave:3000', network='private', project='subpage'):
    return {'Config': {'Image': image, 'Env': ['REMNAWAVE_PANEL_URL=' + panel, 'REMNAWAVE_API_TOKEN=old'], 'Labels': {
        'com.docker.compose.project': project, 'com.docker.compose.service': 'page',
        'com.docker.compose.project.working_dir': '/opt/' + project,
        'com.docker.compose.project.config_files': '/opt/' + project + '/docker-compose.yml'}},
        'NetworkSettings': {'Networks': {network: {}}}, 'State': {'Running': True}}


class MigrationTests(unittest.TestCase):
    def test_internal_alias_requires_this_panels_network_and_no_competing_owner(self):
        panel = container(project='panel')
        panel['Id'] = 'current-panel'
        panel['Config']['Labels']['com.docker.compose.service'] = 'api'
        page = container(panel='http://api:3000')
        self.assertEqual(len(migration.candidates(panel, [page])), 1)
        foreign = container(panel='http://api:3000', network='foreign')
        self.assertEqual(migration.candidates(panel, [foreign]), [])
        other = copy.deepcopy(panel)
        other['Id'] = 'other-panel'
        other['Config']['Image'] = 'other/panel:old'
        self.assertEqual(migration.candidates(panel, [page], [panel, other, page]), [])
        other['NetworkSettings']['Networks'] = {'foreign': {}}
        self.assertEqual(len(migration.candidates(panel, [page], [panel, other, page])), 1)
        page['NetworkSettings']['Networks']['foreign'] = {}
        self.assertEqual(migration.candidates(panel, [page], [panel, other, page]), [])

    def test_public_panel_origin_includes_scheme_and_port(self):
        panel = container(project='panel')
        panel['Config']['Env'] = ['FRONT_END_DOMAIN=https://panel.example.com']
        for endpoint, allowed in [('https://panel.example.com', True), ('https://panel.example.com:443/', True),
                                  ('https://panel.example.com:9443', False), ('http://panel.example.com', False),
                                  ('https://panel.example.com/api', False), ('https://user:pass@panel.example.com', False)]:
            with self.subTest(endpoint=endpoint):
                self.assertEqual(bool(migration.candidates(panel, [container(panel=endpoint, network='external')])), allowed)

    def test_only_pages_bound_to_this_panel_are_offered(self):
        panel = container(project='panel')
        panel['Config']['Env'] = ['FRONT_END_DOMAIN=https://panel.example.com']
        panel['Config']['Labels']['com.docker.compose.service'] = 'remnawave'
        choices = migration.candidates(panel, [container(), container(network='foreign'),
            container(panel='https://foreign.example.com'), container(image='postgres:18'),
            container(panel='https://panel.example.com', network='external', project='external')])
        self.assertEqual([item['project'] for item in choices], ['external', 'subpage'])
        self.assertTrue(all('REMNAWAVE_API_TOKEN' not in json.dumps(item) for item in choices))

    def fixture(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        directory = Path(temp.name).resolve(); deploy = directory / 'subpage'; deploy.mkdir()
        primary = deploy / 'docker-compose.yml'
        config = {'name': 'site', 'services': {'page': {'image': 'old',
            'environment': {'REMNAWAVE_PANEL_URL': 'https://panel.example.com', 'CUSTOM': 'keep'},
            'ports': ['127.0.0.1:3010:3010'], 'volumes': ['/data:/data'], 'networks': ['external']},
            'proxy': {'image': 'nginx:old'}}, 'networks': {'external': {'external': True, 'name': 'legacy'}}}
        runtime.write(primary, config)
        state = directory / 'panel-state.json'
        item = dict(project='site', service='page', directory=str(deploy), composeFiles=[str(primary)], tokenUuid='a')
        runtime.write(state, {'directory': str(directory), 'project': 'panel', 'component': 'panel', 'composeFiles': [], 'subscriptionMigration': item})
        token = directory / 'token'; token.write_text('abc.def.ghi')
        return directory, primary, config, state, token

    def execute(self, fail=False, running=True):
        directory, primary, config, state, token = self.fixture()
        commands = []; attempts = 0
        def run(args, **kwargs):
            nonlocal attempts
            commands.append(args)
            value = ''
            if '--format' in args: value = json.dumps(config)
            elif 'inspect' in args:
                value = json.dumps([{'State': {'Running': running, 'Health': {'Status': 'healthy'}},
                    'Config': {'Image': 'new' if attempts else 'old', 'Env': ['REMNAWAVE_API_TOKEN=abc.def.ghi']}}])
            elif 'ps' in args: value = 'container'
            elif 'up' in args or 'create' in args:
                attempts += 1
                if fail and attempts == 1:
                    return subprocess.CompletedProcess(args, 1, '', 'PRIVATE_TOKEN_MUST_NOT_LEAK')
            return subprocess.CompletedProcess(args, 0, value, '')
        with patch.dict(os.environ, REMNACUST_ROOT=str(directory)):
            if fail:
                with self.assertRaisesRegex(runtime.ConfigurationError, 'Docker') as error:
                    migration.upgrade(state, 'new', token, directory / 'backups', '1.1.7.56', 'v1.2.90', run, lambda _: None)
                self.assertNotIn('PRIVATE_TOKEN', str(error.exception))
                self.assertEqual(runtime.load(primary), config)
                self.assertEqual(attempts, 2)
            else:
                migration.upgrade(state, 'new', token, directory / 'backups', '1.1.7.56', 'v1.2.90', run, lambda _: None)
                result = runtime.load(primary)
                expected = copy.deepcopy(config); expected['services']['page']['image'] = 'new'
                expected['services']['page']['environment']['REMNAWAVE_API_TOKEN'] = 'abc.def.ghi'
                expected['services']['page']['labels'] = {'io.remnacust.service-role': 'subscription-page'}
                result.pop('x-remnacust-release')
                self.assertEqual(result, expected)
                self.assertTrue((primary.parent / 'FILES.txt').is_file())
                self.assertEqual(any('up' in cmd and '--no-start' not in cmd for cmd in commands), running)
            self.assertFalse(any('stop' in cmd or 'down' in cmd for cmd in commands))

    def test_external_page_keeps_ports_volumes_proxy_network_and_panel_address(self): self.execute()
    def test_failed_update_restores_byte_content_and_previous_service(self): self.execute(fail=True)
    def test_stopped_page_is_updated_without_being_started(self): self.execute(running=False)


if __name__ == '__main__': unittest.main()
