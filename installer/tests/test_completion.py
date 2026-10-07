import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'

class CompletionTests(unittest.TestCase):
    def summary(self, component='panel', proxy='caddy', tls=None, action='install-panel', api_port=None):
        with tempfile.TemporaryDirectory(prefix='remnacust-completion-') as directory:
            root = Path(directory)
            deploy = root / 'deployment'
            deploy.mkdir()
            (deploy / '.env').write_text('APP_SECRET=DO-NOT-PRINT\nPOSTGRES_PASSWORD=DO-NOT-PRINT\n'
                                       'SECRET_KEY=DO-NOT-PRINT\nFRONT_END_DOMAIN=https://panel.example.org\nNODE_PORT=2222\n')
            state = {'component': component, 'directory': str(deploy), 'project': 'remnacust-' + component,
                     'proxy': proxy, 'nodeDomain': 'edge.example.org' if component == 'node' else ''}
            if tls: state['tls'] = tls
            if api_port is not None:
                state.update(apiPort=api_port, composeFiles=[str(deploy/'compose.remnacust.json')])
            (root / 'state.json').write_text(json.dumps(state))
            result = subprocess.run(['bash', '-c',
                'source "$1"; WORK="$2"; STATE="$2/state.json"; COMPONENT="$3"; ACTION="$4"; '
                'TAG=v1.2.7; COMPONENT_VERSION=1.1.3; LOG=/test/install.log; '
                'server_addresses() { printf "93.184.216.34\\n2606:4700:4700::1111\\n"; }; completion_summary',
                'test', str(INSTALLER), directory, component, action],
                capture_output=True, text=True, env={**os.environ, 'NO_COLOR': '1'}, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('DO-NOT-PRINT', result.stdout)
            self.assertNotIn('\x1b', result.stdout)
            return result.stdout

    def test_first_login_and_automatic_certificate_are_explained(self):
        output = self.summary()
        for value in ['Адрес входа:', 'https://panel.example.org', 'Создайте аккаунт', '24 символов',
                      'Файл настроек:', '/data', 'автоматически', 'status --component panel']:
            self.assertIn(value, output)

    def test_provided_certificate_keeps_both_original_and_installed_paths_visible(self):
        for component, action in [('panel', 'install-panel'), ('node', 'install-node')]:
            output = self.summary(component, tls={'method': 'existing', 'certificate': '/external/fullchain.pem',
                                                  'key': '/external/privkey.pem'}, action=action)
            for value in ['/external/fullchain.pem', '/external/privkey.pem', '/certs/fullchain.pem',
                          '/certs/privkey.pem', 'renew-' + component + '-certificate']:
                self.assertIn(value, output)
            if component == 'node':
                self.assertIn('TCP 2222', output)
                self.assertIn('Адрес в панели:', output)
                self.assertIn('93.184.216.34', output)
                self.assertIn('2606:4700:4700::1111', output)
                self.assertIn('Порт в панели: 2222', output)
                self.assertIn('SSH:', output)
                self.assertIn('/var/lib/remnacust/tls/fullchain.pem', output)
                self.assertIn('edge.example.org', output)

    def test_external_proxy_does_not_claim_a_generated_certificate(self):
        output = self.summary(proxy='existing')
        self.assertIn('конфигурации вашего proxy', output)
        self.assertNotIn('получает и продлевает', output)

    def test_upgrades_keep_existing_login_and_discover_the_url_from_environment(self):
        output = self.summary(action='upgrade-panel')
        self.assertIn('https://panel.example.org', output)
        self.assertIn('Прежние имя пользователя и пароль', output)
        self.assertNotIn('Создайте аккаунт', output)

    def test_node_upgrade_shows_live_port_and_managed_compose_despite_stale_env(self):
        output = self.summary(component='node', action='upgrade-node', api_port=72)
        self.assertIn('TCP 72', output)
        self.assertNotIn('TCP 2222', output)
        self.assertIn('compose.remnacust.json', output)
        self.assertIn('Сохранён из прежнего контейнера', output)

if __name__ == '__main__':
    unittest.main()
