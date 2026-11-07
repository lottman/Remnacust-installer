import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'
GENERATION = 'b' * 64
FAKE_COMMAND = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['NODE_SITE_FIXTURE'])
helper = Path(sys.argv[0]).name == 'node_site.py'
kind, args = ('site', sys.argv[1:]) if helper else (sys.argv[1], sys.argv[2:])
with (root / 'events.jsonl').open('a', encoding='utf-8') as stream:
    stream.write(json.dumps({'kind': kind, 'args': args}) + '\n')
if kind == 'site':
    restoring = '--restore' in args
    if os.environ.get('FAIL_RESTORE' if restoring else 'FAIL_REPLACE') == '1':
        print('fixture site operation failed', file=sys.stderr)
        raise SystemExit(35)
    backup = root / 'backups' / 'node-sites' / ('node-site-' + 'a' * 32)
    if restoring:
        if '--expected-generation' not in args or args[args.index('--expected-generation') + 1] != 'b' * 64:
            raise SystemExit('restore requires the published generation')
        if args[args.index('--restore') + 1] != str(backup):
            raise SystemExit('restore requires the returned backup')
    elif '--replace' not in args:
        raise SystemExit('explicit configure requires replacement')
    print(json.dumps({'status': 'restored' if restoring else 'replaced', 'changed': True,
                      'directory': str(root / 'node' / 'www'), 'template': 'fixture',
                      'generation': ('a' if restoring else 'b') * 64, 'backup': str(backup)}))
elif kind == 'docker':
    if args != ['inspect', '--format', '{{.State.Running}}', 'fixture-nginx']:
        raise SystemExit('unexpected Docker operation')
    if os.environ.get('FAIL_INSPECT') == '1':
        print('fixture inspect failed', file=sys.stderr)
        raise SystemExit(31)
    print(os.environ.get('NGINX_RUNNING', 'true'))
elif kind == 'compose':
    if args == ['ps', '--all', '--quiet', 'node-nginx']:
        if os.environ.get('NGINX_EXISTS', '1') == '1':
            print('fixture-nginx')
    elif args and args[0] == 'up':
        counter = root / 'up-count'
        count = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(count))
        if str(count) in os.environ.get('FAIL_UP_CALLS', '').split(','):
            print('fixture recreate failed', file=sys.stderr)
            raise SystemExit(23)
    elif args == ['exec', '-T', 'node-nginx', 'nginx', '-t']:
        counter = root / 'exec-count'
        count = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(count))
        if str(count) in os.environ.get('FAIL_EXEC_CALLS', '').split(','):
            print('fixture nginx check failed', file=sys.stderr)
            raise SystemExit(24)
    else:
        raise SystemExit('unexpected Compose operation')
else:
    raise SystemExit('unexpected fixture command')
'''

SHELL = r'''
source "$1"
ROOT="$2"
export REMNACUST_ROOT="$ROOT"
WORK="$ROOT/work"
DEPLOY="$ROOT/node"
HELPER_ROOT="$ROOT/helpers"
installed_helper() { :; }
lock_operation() { :; }
load_state() { APPS=(remnanode fixture-app); EXTRAS=(node-nginx fixture-extra); }
assert_not_uninstalled() { :; }
confirm() { :; }
get() { [[ $1 == nodeDomain ]] || return 97; printf '%s\n' node.example.test; }
info() { printf '%s\n' "$*"; }
compose() { "$FIXTURE_PYTHON" "$NODE_SITE_FIXTURE/commands.py" compose "$@"; }
docker() { "$FIXTURE_PYTHON" "$NODE_SITE_FIXTURE/commands.py" docker "$@"; }
prepare_host() { return 97; }
node_acl() { return 97; }
systemctl() { return 97; }
apt-get() { return 97; }
configure_node_site
'''


@unittest.skipIf(os.name == 'nt', 'Requires POSIX Bash; run under WSL or Linux CI')
class NodeSiteCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='node site cli ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ['helpers', 'registry', 'node', 'work']:
            (self.root / name).mkdir()
        (self.root / 'registry' / 'node.json').write_text('{}', encoding='utf-8')
        (self.root / 'events.jsonl').write_text('', encoding='utf-8')
        (self.root / 'helpers' / 'node_site.py').write_text(FAKE_COMMAND, encoding='utf-8')
        (self.root / 'commands.py').write_text(FAKE_COMMAND, encoding='utf-8')

    def run_cli(self, **settings):
        environment = {**os.environ, 'NODE_SITE_FIXTURE': str(self.root),
                       'FIXTURE_PYTHON': sys.executable, 'PYTHONDONTWRITEBYTECODE': '1',
                       'LC_ALL': 'C.UTF-8', **settings}
        result = subprocess.run(['bash', '-c', SHELL, 'fixture', str(INSTALLER), str(self.root)],
                                env=environment, capture_output=True, text=True, encoding='utf-8', timeout=15)
        events = [json.loads(line) for line in (self.root / 'events.jsonl').read_text().splitlines()]
        return result, events

    def recreates(self, events):
        commands = [event['args'] for event in events
                    if event['kind'] == 'compose' and event['args'][0] == 'up']
        for args in commands:
            self.assertEqual(args, ['up', '-d', '--no-deps', '--no-build', '--pull', 'never',
                                    '--force-recreate', 'node-nginx'])
        return commands

    def checks(self, events):
        commands = [event['args'] for event in events
                    if event['kind'] == 'compose' and event['args'][0] == 'exec']
        for args in commands:
            self.assertEqual(args, ['exec', '-T', 'node-nginx', 'nginx', '-t'])
        return commands

    def sites(self, events):
        return [event['args'] for event in events if event['kind'] == 'site']

    def assert_restore(self, args):
        self.assertIn('--restore', args)
        self.assertEqual(args[args.index('--restore') + 1],
                         str(self.root / 'backups' / 'node-sites' / ('node-site-' + 'a' * 32)))
        self.assertIn('--expected-generation', args)
        self.assertEqual(args[args.index('--expected-generation') + 1], GENERATION)
        self.assertNotIn('--replace', args)

    def assert_no_success(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('Сайт обновлён.', result.stdout)

    def test_running_nginx_is_remounted_without_restarting_node_applications(self):
        result, events = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.sites(events)), 1)
        self.assertEqual(len(self.recreates(events)), 1)
        self.assertEqual(len(self.checks(events)), 1)
        self.assertLess(next(index for index, event in enumerate(events) if event['kind'] == 'site'),
                        next(index for index, event in enumerate(events)
                             if event['kind'] == 'compose' and event['args'][0] == 'up'))

    def test_stopped_nginx_remains_stopped_after_site_replacement(self):
        result, events = self.run_cli(NGINX_RUNNING='false')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.sites(events)), 1)
        self.assertEqual(self.recreates(events), [])
        self.assertEqual(self.checks(events), [])

    def test_absent_nginx_is_not_started_after_site_replacement(self):
        result, events = self.run_cli(NGINX_EXISTS='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.sites(events)), 1)
        self.assertEqual(self.recreates(events), [])
        self.assertFalse(any(event['kind'] == 'docker' for event in events))

    def test_failed_recreate_restores_returned_backup_and_generation_before_remount(self):
        result, events = self.run_cli(FAIL_UP_CALLS='1')
        self.assert_no_success(result)
        operations = self.sites(events)
        self.assertEqual(len(operations), 2, events)
        self.assert_restore(operations[1])
        self.assertEqual(len(self.recreates(events)), 2)
        phases = [event['kind'] if event['kind'] == 'site' else 'up'
                  for event in events if event['kind'] == 'site' or
                  (event['kind'] == 'compose' and event['args'][0] == 'up')]
        self.assertEqual(phases, ['site', 'up', 'site', 'up'])

    def test_failed_guarded_restore_reports_failure_without_remount_or_false_success(self):
        result, events = self.run_cli(FAIL_UP_CALLS='1', FAIL_RESTORE='1')
        self.assert_no_success(result)
        operations = self.sites(events)
        self.assertEqual(len(operations), 2, events)
        self.assert_restore(operations[1])
        self.assertEqual(len(self.recreates(events)), 1)

    def test_failed_remount_after_successful_restore_reports_failure(self):
        result, events = self.run_cli(FAIL_UP_CALLS='1,2')
        self.assert_no_success(result)
        operations = self.sites(events)
        self.assertEqual(len(operations), 2, events)
        self.assert_restore(operations[1])
        self.assertEqual(len(self.recreates(events)), 2)

    def test_failed_site_replace_does_not_restart_services_or_attempt_restore(self):
        result, events = self.run_cli(FAIL_REPLACE='1')
        self.assert_no_success(result)
        self.assertEqual(len(self.sites(events)), 1)
        self.assertEqual(self.recreates(events), [])

    def test_failed_running_state_check_does_not_replace_site_or_report_success(self):
        result, events = self.run_cli(FAIL_INSPECT='1')
        self.assert_no_success(result)
        self.assertEqual(self.sites(events), [])
        self.assertEqual(self.recreates(events), [])

    def test_invalid_running_state_does_not_replace_site_or_report_success(self):
        result, events = self.run_cli(NGINX_RUNNING='unknown')
        self.assert_no_success(result)
        self.assertEqual(self.sites(events), [])
        self.assertEqual(self.recreates(events), [])

    def test_uninstalled_node_aborts_before_site_or_docker_operations(self):
        (self.root / 'registry' / 'node.json').write_text(
            json.dumps({'component': 'node', 'uninstalled': True}), encoding='utf-8')
        result, events = self.run_cli()
        self.assert_no_success(result)
        self.assertEqual(events, [])

    def test_successful_up_with_failed_nginx_check_restores_previous_site_before_ready_message(self):
        result, events = self.run_cli(FAIL_EXEC_CALLS='1')
        self.assert_no_success(result)
        operations = self.sites(events)
        self.assertEqual(len(operations), 2, events)
        self.assert_restore(operations[1])
        self.assertEqual(len(self.recreates(events)), 2)
        self.assertEqual(len(self.checks(events)), 2)
        phases = [event['args'][0] if event['kind'] == 'compose' else
                  'restore' if '--restore' in event['args'] else 'replace'
                  for event in events if event['kind'] == 'site' or
                  (event['kind'] == 'compose' and event['args'][0] in {'up', 'exec'})]
        self.assertEqual(phases, ['replace', 'up', 'exec', 'restore', 'up', 'exec'])

    def test_failed_nginx_check_after_rollback_does_not_claim_previous_site_is_ready(self):
        result, events = self.run_cli(FAIL_UP_CALLS='1', FAIL_EXEC_CALLS='1')
        self.assert_no_success(result)
        operations = self.sites(events)
        self.assertEqual(len(operations), 2, events)
        self.assert_restore(operations[1])
        self.assertEqual(len(self.recreates(events)), 2)
        self.assertEqual(len(self.checks(events)), 1)
        self.assertNotIn('предыдущий сайт восстановлен', result.stdout.lower())


if __name__ == '__main__':
    unittest.main()
