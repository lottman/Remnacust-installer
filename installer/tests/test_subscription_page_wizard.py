import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'


@unittest.skipIf(os.name == 'nt', 'Requires native Bash')
class PageWizardTests(unittest.TestCase):
    def run_wizard(self, choices, missing=False, explicit=False, failure=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            helpers = root / 'helpers'
            helpers.mkdir()
            (helpers / 'subscription_pages.py').write_text("""import json,os,sys
from pathlib import Path
root=Path(os.environ['PAGE_FIXTURE'])
if sys.argv[1]=='migration-candidates':print(os.environ['PAGE_CHOICES'])
elif sys.argv[1]=='migrate':
 (root/'migrate.json').write_text(json.dumps(sys.argv[2:]))
 if '--token-file' in sys.argv:
  path=Path(sys.argv[sys.argv.index('--token-file')+1]);assert path.read_text()=='fixture.new.token';assert path.stat().st_mode & 0o077==0
 sys.exit(23 if os.environ.get('PAGE_FAILURE')=='1' else 0)
else:raise SystemExit(99)
""")
            script = r'''source "$1"
WORK="$PAGE_FIXTURE"; ROOT="$PAGE_FIXTURE/state"; LOG="$PAGE_FIXTURE/log"; ACTION=migrate-remnawave-subscription-page
installed_helper() { HELPER_ROOT="$PAGE_FIXTURE/helpers"; }
lock_operation() { printf 'lock\n' >> "$PAGE_FIXTURE/events"; }
prepare_host() { :; }; choose_version() { VERSION=latest; }; confirm() { :; }
release_source() { TAG=v1.2.153; }; select_subscription_image() { SUBSCRIPTION_IMAGE=page:new; SUBSCRIPTION_IMAGE_VERSION=1.1.7.107; }
prepare_subscription_image() { :; }; step() { shift; "$@"; }
install_cli() { printf 'installed-cli\n' >> "$PAGE_FIXTURE/events"; }
subscription_page_action() { printf 'wizard:%s\n' "$ACTION" >> "$PAGE_FIXTURE/events"; }
subscription_panel_endpoint() { printf 'https://panel.example.test'; }
subscription_page_token() { printf 'fixture.new.token' > "$2"; chmod 600 "$2"; printf 'asked-connection\n' >> "$PAGE_FIXTURE/events"; }
if [[ $PAGE_EXPLICIT == 1 ]]; then CONTAINER=selected-page; fi
migrate_subscription_page_action
'''
            env = {**os.environ, 'PAGE_FIXTURE': str(root), 'PAGE_CHOICES': json.dumps(choices),
                   'PAGE_FAILURE': '1' if failure else '0', 'PAGE_EXPLICIT': '1' if explicit else '0'}
            result = subprocess.run(['bash', '-c', script, 'fixture', str(INSTALLER)], env=env, capture_output=True, text=True, timeout=15)
            events = (root / 'events').read_text().splitlines() if (root / 'events').exists() else []
            args = json.loads((root / 'migrate.json').read_text()) if (root / 'migrate.json').exists() else None
            return result, events, args, (root / 'page-migration-token.txt').exists()

    def choice(self, connection=False):
        return [{'project': 'subscription', 'service': 'remnawave-subscription-page',
                 'directory': '/opt/subscription', 'container': 'a' * 64, 'needsConnection': connection}]

    def test_absent_source_opens_install_wizard_without_migration_or_double_lock(self):
        result, events, args, _ = self.run_wizard([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ['wizard:install-subscription-page'])
        self.assertIsNone(args)

    def test_unrecognized_explicit_source_is_never_silently_replaced(self):
        result, events, args, _ = self.run_wizard([], explicit=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])
        self.assertIsNone(args)

    def test_available_connection_is_kept(self):
        result, events, args, _ = self.run_wizard(self.choice())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ['lock', 'installed-cli'])
        self.assertNotIn('--panel-url', args)

    def test_missing_connection_requests_endpoint_and_private_token(self):
        result, events, args, retained = self.run_wizard(self.choice(True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ['lock', 'asked-connection', 'installed-cli'])
        self.assertEqual(args[args.index('--panel-url') + 1], 'https://panel.example.test')
        self.assertFalse(retained)

    def test_failed_migration_cleans_prompted_token_and_never_reports_success(self):
        result, events, _, retained = self.run_wizard(self.choice(True), failure=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(events, ['lock', 'asked-connection'])
        self.assertFalse(retained)
        self.assertNotIn('Страница перенесена', result.stdout)


if __name__ == '__main__':
    unittest.main()
