import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import tls


class SubscriptionPageTests(unittest.TestCase):
    def test_domains_require_a_distinct_host_without_a_path(self):
        self.assertEqual(runtime.subscription_domains(' Sub.Example.com/,https://alias.example.com ', 'panel.example.com'),
                         ['sub.example.com', 'alias.example.com'])
        for value in ['', 'panel.example.com', 'sub.example.com/path', 'sub.example.com,sub.example.com', 'http://sub.example.com']:
            with self.subTest(value=value), self.assertRaises(runtime.ConfigurationError):
                runtime.subscription_domains(value, 'panel.example.com')

    def test_bundle_is_opt_in_and_does_not_expose_public_ports_or_admin(self):
        with tempfile.TemporaryDirectory() as directory:
            config, state = runtime.fresh('panel', directory, 'fixture-panel', 'panel:fixture', 'panel.example.com')
            self.assertNotIn('remnawave-subscription-page', config['services'])
            self.assertNotIn('subscriptionPage', state)
            config, state = runtime.fresh('panel', directory, 'fixture-panel', 'panel:fixture', 'panel.example.com',
                                         subscriptions='sub.example.com,alias.example.com', subscription_image='page:fixture')
            page = config['services']['remnawave-subscription-page']
            self.assertEqual(page['ports'], ['127.0.0.1:3010:3010'])
            self.assertEqual(page['profiles'], ['subscription'])
            self.assertEqual(page['labels']['io.remnacust.service-role'], 'subscription-page')
            self.assertIn('remnawave-subscription-page', state['ownedServices'])
            self.assertIn('remnawave-subscription-page', state['applications'])
            self.assertTrue(state['subscriptionPage'])
            import uuid
            self.assertEqual(uuid.UUID(state['subscriptionTokenUuid']).version, 4)
            tls.caddy('panel.example.com', 'fixture@example.com', 'auto', directory, 'sub.example.com,alias.example.com')
            contents = (Path(directory)/'Caddyfile').read_text()
            self.assertIn('sub.example.com, alias.example.com {\n    reverse_proxy remnawave-subscription-page:3010', contents)
            self.assertEqual(contents.count('reverse_proxy remnawave:3000'), 1)
            for number in ['3000', '80', '443']:
                with self.assertRaises(runtime.ConfigurationError):
                    runtime.fresh('panel', directory, 'fixture-panel', 'panel:fixture', 'panel.example.com',
                                  subscriptions='sub.example.com', subscription_image='page:fixture', subscription_port=number)

    def test_update_changes_managed_page_only_and_retains_credentials_and_bindings(self):
        with tempfile.TemporaryDirectory() as directory:
            config, state = runtime.fresh('panel', directory, 'fixture-panel', 'panel:old', 'panel.example.com',
                                         subscriptions='sub.example.com', subscription_image='page:old')
            config['services']['foreign-page'] = {'image': 'page:old', 'env_file': ['foreign.env']}
            container = {'Config': {'Labels': {'com.docker.compose.service': 'remnawave'}}}
            updated, apps = runtime.transform(config, container, 'panel', 'panel:new', subscription_image='page:new')
            self.assertEqual(updated['services']['remnawave-subscription-page']['image'], 'page:new')
            self.assertEqual(updated['services']['foreign-page']['image'], 'page:old')
            before = {**config['services']['remnawave-subscription-page'], 'image': 'page:new'}
            self.assertEqual(updated['services']['remnawave-subscription-page'], before)
            self.assertIn('remnawave-subscription-page', apps)

    def test_protected_environment_uses_internal_network_and_no_credentials_in_urls(self):
        env = dict(line.split('=', 1) for line in runtime.subscription_env('abc.def.xyz').splitlines())
        self.assertEqual(env['REMNAWAVE_PANEL_URL'], 'http://remnawave:3000')
        self.assertEqual(env['REMNAWAVE_API_TOKEN'], 'abc.def.xyz')
        self.assertEqual(len(env['INTERNAL_JWT_SECRET']), 64)
        self.assertEqual(env['MARZBAN_LEGACY_LINK_ENABLED'], 'false')
        with self.assertRaises(runtime.ConfigurationError):
            runtime.subscription_env('secret\nEVIL=1')

    @unittest.skipIf(os.name == 'nt', 'Linux CLI workflow')
    def test_explicit_unattended_install_or_decline_and_invalid_actions(self):
        installer = Path(runtime.__file__).with_name('installer.sh')
        for flags, expected, success in [
            (['install-panel', '--subscription-page', '--subscription-urls', 'sub.example.com,alias.example.com'],
             'RESULT=true|https://sub.example.com,https://alias.example.com', True),
            (['install-panel', '--no-subscription-page'], 'RESULT=false|https://panel.example.com/api/sub', True),
            (['install-panel', '--subscription-page'], 'Исправьте --subscription-urls', False),
            (['install-panel', '--subscription-page', '--subscription-urls', 'panel.example.com'], 'Исправьте --subscription-urls', False),
            (['upgrade-panel', '--subscription-page'], 'только для новой панели', False),
            (['install-node', '--subscription-page'], 'только для новой панели', False),
            (['install-panel', '--subscription-page', '--no-subscription-page'], 'Выберите один', False),
        ]:
            result = subprocess.run(['bash', '-c', 'source "$1"; shift; parse_args "$@"; DOMAIN=panel.example.com; '
                                      'HELPER="'+runtime.__file__+'"; subscription_wizard; printf "RESULT=%s|%s" "$SUBSCRIPTION_PAGE" "$SUBSCRIPTION_URLS"',
                                      'test', str(installer), *flags], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            self.assertIn(expected, result.stdout + result.stderr)

    @unittest.skipIf(os.name == 'nt', 'OpenSSL on Linux')
    def test_manual_certificate_and_renewal_validate_all_domains_before_copying(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key, cert = root/'key.pem', root/'cert.pem'
            for san, valid in [('DNS:panel.example.com,DNS:sub.example.com,DNS:alias.example.com', True),
                               ('DNS:panel.example.com,DNS:sub.example.com', False)]:
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3',
                                '-subj', '/CN=panel.example.com', '-addext', 'subjectAltName='+san,
                                '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
                if valid:
                    tls.copy_pair('panel.example.com', cert, key, directory, 'sub.example.com,alias.example.com')
                    previous = (root/'certs/fullchain.pem').read_bytes()
                else:
                    with self.assertRaisesRegex(ValueError, 'все домены'):
                        tls.copy_pair('panel.example.com', cert, key, directory, 'sub.example.com,alias.example.com')
                    self.assertEqual((root/'certs/fullchain.pem').read_bytes(), previous)

    @unittest.skipIf(os.name == 'nt', 'Linux DNS preflight')
    def test_dns_checks_both_domains_and_stops_on_a_bad_alias(self):
        installer = Path(runtime.__file__).with_name('installer.sh')
        for bad_alias in [False, True]:
            script = ('source "$1"; HELPER="'+runtime.__file__+'"; COMPONENT=panel; DOMAIN=panel.example.com; '
                      'PROXY=caddy; TLS_METHOD=auto; SUBSCRIPTION_PAGE=true; '
                      'SUBSCRIPTION_URLS=sub.example.com,alias.example.com; '
                      'check_dns() { printf "CHECK:%s\\n" "$1"; '+
                      ('[[ $1 != alias.example.com ]];' if bad_alias else 'return 0;')+
                      ' }; dns_preflight; printf FINISHED')
            result = subprocess.run(['bash', '-c', script, 'test', str(installer)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode == 0, not bad_alias, result.stderr)
            self.assertIn('CHECK:panel.example.com\nCHECK:sub.example.com\nCHECK:alias.example.com', result.stdout)
            self.assertEqual('FINISHED' in result.stdout, not bad_alias)


if __name__ == '__main__':
    unittest.main()
