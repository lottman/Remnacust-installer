import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import subscription_pages as pages
import subscription_connection as connection


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        env = patch.dict(os.environ, REMNACUST_ROOT=str(self.root))
        env.start(); self.addCleanup(env.stop)
        self.directory = self.root / 'page'; self.directory.mkdir()
        self.env = self.directory / '.env'
        self.env.write_text('REMNAWAVE_PANEL_URL=https://old.example.test\nREMNAWAVE_API_TOKEN=old.valid.token\nKEEP=unchanged\n')
        self.env.chmod(0o600)
        self.compose = self.directory / 'docker-compose.yml'
        self.config = {'services': {'page': {'image': 'page:current', 'env_file': [str(self.env)]},
                                    'database': {'image': 'postgres:18'}}}
        runtime.write(self.compose, self.config)
        self.item = {'directory': str(self.directory), 'project': 'page-test', 'service': 'page',
                     'composeFiles': [str(self.compose)], 'domain': 'subscription.example.test'}
        self.page = pages.identity(self.item)
        runtime.write(self.root / 'registry/subscription-pages' / (self.page + '.json'), self.item)
        self.commands = []
        self.current = {'State': {'Running': True}, 'Config': {'Image': 'page:current'}}

    def command(self, base, *args):
        self.commands.append([*base, *args])
        if '--format' in args:
            return json.dumps(self.config)
        return ''

    def execute(self, ready_error=None):
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), \
                patch.object(connection, 'probe') as probe, patch.object(pages, 'ready', side_effect=ready_error) as ready:
            pages.configure(self.root, self.page, 'new.example.test:8443', 'new.valid.token')
            return probe, ready

    def test_configure_preserves_other_service_image_and_private_settings(self):
        self.execute()
        self.assertEqual(runtime.load(self.compose), self.config)
        text = self.env.read_text()
        self.assertIn('https://new.example.test:8443', text)
        self.assertIn('new.valid.token', text)
        self.assertIn('KEEP=unchanged', text)
        self.assertTrue(any(command[-1] == 'page' and '--no-deps' in command for command in self.commands))
        self.assertFalse(any('database' in command for command in self.commands))
        self.assertEqual(self.env.stat().st_mode & 0o077, 0)

    def test_failed_readiness_or_interruption_restores_original_environment_and_compose(self):
        original_env, original_compose = self.env.read_bytes(), self.compose.read_bytes()
        for error in [ValueError('readiness'), KeyboardInterrupt()]:
            with self.subTest(error=type(error)), self.assertRaises(type(error)):
                self.execute(error)
            self.assertEqual(self.env.read_bytes(), original_env)
            self.assertEqual(self.compose.read_bytes(), original_compose)

    def test_stopped_page_stays_stopped(self):
        self.current['State']['Running'] = False
        probe, ready = self.execute()
        probe.assert_called_once()
        ready.assert_not_called()
        self.assertTrue(any('--no-start' in command for command in self.commands))
        self.assertFalse(any('-d' in command for command in self.commands))

    def test_shared_environment_is_not_modified_for_other_services(self):
        self.config['services']['database']['env_file'] = [str(self.env)]
        runtime.write(self.compose, self.config)
        original = self.env.read_bytes()
        self.execute()
        updated = runtime.load(self.compose)
        self.assertEqual(self.env.read_bytes(), original)
        self.assertEqual(updated['services']['database'], self.config['services']['database'])
        self.assertEqual(updated['services']['page']['environment']['REMNAWAVE_API_TOKEN'], 'new.valid.token')

    def test_probe_failure_does_not_change_settings_or_create_a_backup(self):
        original = self.env.read_bytes()
        with patch.object(pages, 'command', side_effect=self.command), patch.object(pages, 'inspect', return_value=self.current), \
                patch.object(connection, 'probe', side_effect=ValueError('invalid access')), self.assertRaises(ValueError):
            pages.configure(self.root, self.page, 'https://new.example.test', 'new.valid.token')
        self.assertEqual(self.env.read_bytes(), original)
        self.assertFalse((self.root / 'backups').exists())

    def test_endpoint_normalization_and_https_requirement(self):
        self.assertEqual(connection.resolve(self.root, 'panel.example.test:8443/', None), ('https://panel.example.test:8443', None))
        for value in ['http://panel.example.test', 'https://user:pass@panel.example.test', 'https://panel.example.test/dashboard',
                      'https://panel.example.test?token=private', 'https://panel.example.test\nBAD=value', 'https://panel.example.test:0']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                connection.resolve(self.root, value, None)

    def test_local_network_keeps_existing_aliases_and_other_service_networks(self):
        config = copy.deepcopy(self.config)
        config['networks'] = {'panel': {'external': True, 'name': 'live-panel'}}
        config['services']['page']['networks'] = {'panel': {'aliases': ['page-alias']}}
        original_other = copy.deepcopy(config['services']['database'])
        connection.edit(config, self.item, 'http://panel:3000', 'new.valid.token', 'live-panel')
        self.assertEqual(config['services']['page']['networks']['panel']['aliases'], ['page-alias'])
        self.assertEqual(config['services']['database'], original_other)

    def test_probe_passes_token_only_in_private_file_and_hides_command_failures(self):
        commands = []
        def command(base, *args):
            commands.append([*base, *args])
            path = Path(args[args.index('--env-file') + 1])
            self.assertEqual(path.stat().st_mode & 0o077, 0)
            self.assertIn('new.valid.token', path.read_text())
            raise subprocess.CalledProcessError(1, 'unsafe diagnostic new.valid.token')
        with self.assertRaisesRegex(ValueError, '^PANEL_ACCESS_FAILED$'):
            connection.probe('page:current', 'https://panel.example.test', 'new.valid.token', None, None, command)
        self.assertNotIn('new.valid.token', str(commands))

    def test_token_file_refuses_public_permissions_symlinks_and_pipes(self):
        token = self.root / 'token'; token.write_text('new.valid.token\n'); token.chmod(0o600)
        self.assertEqual(connection.read_token(token), 'new.valid.token')
        token.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'PRIVATE'):
            connection.read_token(token)
        token.chmod(0o600)
        link = self.root / 'link'; link.symlink_to(token)
        with self.assertRaises(OSError): connection.read_token(link)
        pipe = self.root / 'pipe'; os.mkfifo(pipe)
        with self.assertRaises(ValueError): connection.read_token(pipe)

    def test_node_probe_checks_scopes_and_never_follows_redirects(self):
        seen = []
        mode = {'value': 'ok'}
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get('Authorization')))
                if mode['value'] == 'redirect':
                    self.send_response(302); self.send_header('Location', '/leaked'); self.end_headers(); return
                if mode['value'] == 'denied' and self.path.endswith('subscription-page-configs'):
                    self.send_response(403); self.end_headers(); return
                body = {'response': {'version': '1.1.7.71'}} if self.path.endswith('metadata') else {'response': {'configs': []}}
                if mode['value'] == 'html':
                    raw = b'<html>login</html>'
                else: raw = json.dumps(body).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            for value in ['ok', 'denied', 'redirect', 'html']:
                mode['value'] = value; seen.clear()
                result = subprocess.run(['node', '-e', connection.PROBE], env={**os.environ,
                    'REMNAWAVE_PANEL_URL': 'http://127.0.0.1:' + str(server.server_port), 'REMNAWAVE_API_TOKEN': 'new.valid.token'}, capture_output=True, text=True, timeout=12)
                self.assertEqual(result.returncode == 0, value == 'ok', value)
                self.assertNotIn('new.valid.token', result.stdout + result.stderr)
                self.assertFalse(any(path == '/leaked' for path, _ in seen))
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__': unittest.main()
