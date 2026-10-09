import os
from pathlib import Path
import subprocess
import sys
import tempfile
import json
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class SubscriptionUrlTests(unittest.TestCase):
    @unittest.skipIf(os.name == 'nt', 'Bash discovery is checked on Linux')
    def test_upgrade_keeps_aliases_only_for_the_same_compose_installation(self):
        installer = Path(runtime.__file__).with_name('installer.sh')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deploy = root / 'deployment'
            deploy.mkdir()
            compose = deploy / 'compose.json'
            config = {'services': {'remnawave': {'image': 'old'}}}
            compose.write_text(json.dumps(config))
            container = {'Id': 'fixture', 'Config': {'Env': ['APP_SECRET=fixture-only', 'DATABASE_URL=postgresql://fixture'],
                         'Labels': {'com.docker.compose.project': 'fixture-panel',
                                    'com.docker.compose.service': 'remnawave',
                                    'com.docker.compose.project.working_dir': str(deploy),
                                    'com.docker.compose.project.config_files': str(compose)}}}
            (root / 'inspect.json').write_text(json.dumps([container]))
            (root / 'config.json').write_text(json.dumps(config))
            (root / 'registry').mkdir()
            for project, expected in [('fixture-panel', True), ('another-panel', False)]:
                aliases = ['https://sub.example.com', 'https://other.example.com']
                (root / 'registry/panel.json').write_text(json.dumps({'project': project, 'directory': str(deploy),
                                                                    'subscriptionUrls': aliases}))
                script = '''source "$1"
ROOT="$2"; WORK="$2"; HELPER="$3"; COMPONENT=panel; CONTAINER=fixture; IMAGE=new
docker() { if [[ $1 == inspect ]]; then cat "$WORK/inspect.json"; else printf fixture; fi; }
compose() { cat "$WORK/config.json"; }
capture_running_apps() { RUNNING_APPS=(remnawave); }
find_existing
'''
                result = subprocess.run(['bash', '-c', script, 'test', str(installer), directory, runtime.__file__],
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads((root / 'state.json').read_text())
                self.assertEqual(state.get('subscriptionUrls'), aliases if expected else None)

    @unittest.skipIf(os.name == 'nt', 'Bash workflow is checked on Linux')
    def test_noninteractive_wizard_defaults_flags_and_older_helper(self):
        installer = Path(runtime.__file__).with_name('installer.sh')
        with tempfile.TemporaryDirectory() as directory:
            legacy = Path(directory) / 'legacy.py'
            legacy.write_text('print("usage: legacy runtime --domain DOMAIN")\n')
            command = ('source "$1"; DOMAIN=panel.example.com; HELPER="$2"; '
                       'SUBSCRIPTION_URLS="$3"; subscription_wizard; printf "RESULT=%s" "$SUBSCRIPTION_URLS"')
            for helper, value, expected, success in [
                (runtime.__file__, '', 'RESULT=https://panel.example.com/api/sub', True),
                (runtime.__file__, 'sub.example.com,other.example.com',
                 'RESULT=https://sub.example.com,https://other.example.com', True),
                (runtime.__file__, 'http://sub.example.com', 'Исправьте --subscription-urls', False),
                (str(legacy), '', 'RESULT=', True),
                (str(legacy), 'sub.example.com', 'Выберите latest', False),
            ]:
                result = subprocess.run(['bash', '-c', command, 'test', str(installer), helper, value],
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                self.assertIn(expected, result.stdout + result.stderr)

    @unittest.skipIf(os.name == 'nt', 'Bash workflow is checked on Linux')
    def test_cli_rejects_changing_urls_during_upgrade_or_node_install(self):
        installer = Path(runtime.__file__).with_name('installer.sh')
        for action in ['upgrade-panel', 'install-node']:
            result = subprocess.run(['bash', '-c', 'source "$1"; parse_args "$2" --subscription-urls sub.example.com',
                                     'test', str(installer), action], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('для новой панели', result.stderr)

    def test_omitted_value_preserves_current_panel_subscription_endpoint(self):
        self.assertEqual(runtime.subscription_urls('', 'Panel.Example.com'),
                         ['https://panel.example.com/api/sub'])

    def test_domains_https_urls_custom_prefix_and_trailing_slash(self):
        self.assertEqual(runtime.subscription_urls(' Sub.Example.com/sub/, https://Other.Example.com/sub ', 'panel.example.com'),
                         ['https://sub.example.com/sub', 'https://other.example.com/sub'])
        self.assertEqual(runtime.subscription_urls('HTTPS://sub.example.com/', 'panel.example.com'),
                         ['https://sub.example.com'])

    def test_invalid_and_duplicate_addresses_are_rejected_without_echoing_input(self):
        for value in [' ', ',sub.example.com', 'sub.example.com,', 'a.example.com,b.example.com,c.example.com',
                      'http://sub.example.com', 'https://user:password@sub.example.com',
                      'https://sub.example.com:443', 'https://127.0.0.1', 'https://sub.example.com?token=secret',
                      'sub.example.com/#secret', 'sub.example.com/../sub', 'sub.example.com/sub//path',
                      'sub.example.com/sub\nAPP_SECRET=secret', 'sub.example.com/$(id)',
                      'sub.example.com/'+'a'*1024, 'a'*2051,
                      'sub.example.com/sub,HTTPS://SUB.EXAMPLE.COM/sub/']:
            with self.subTest(value=value), self.assertRaises(runtime.ConfigurationError) as caught:
                runtime.subscription_urls(value, 'panel.example.com')
            if value.strip():
                self.assertNotIn(value, str(caught.exception))

    def test_only_primary_url_is_used_for_links_and_both_are_recorded(self):
        value = 'https://sub.example.com/sub,backup.example.com/sub'
        text = runtime.panel_env('SUB_PUBLIC_DOMAIN=old.example.com/api/sub\n', 'panel.example.com', 3000, value)
        self.assertIn('SUB_PUBLIC_DOMAIN=sub.example.com/sub\n', text)
        self.assertNotIn('backup.example.com', text)
        self.assertNotIn('SUB_PUBLIC_DOMAIN=https://', text)
        _, state = runtime.fresh('panel', '/opt/test', 'test-panel', 'app', 'panel.example.com', subscriptions=value)
        self.assertEqual(state['subscriptionUrls'], ['https://sub.example.com/sub', 'https://backup.example.com/sub'])

    def test_cli_normalizes_both_addresses(self):
        result = subprocess.run([sys.executable, runtime.__file__, 'subscription-urls', '--domain', 'panel.example.com',
                                 '--subscription-urls', 'sub.example.com, https://backup.example.com/'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['https://sub.example.com', 'https://backup.example.com'])


if __name__ == '__main__':
    unittest.main()
