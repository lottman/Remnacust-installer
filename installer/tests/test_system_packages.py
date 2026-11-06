import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_input


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'
SETUP = 'source "$1"; WORK="$2"; LOG="$2/packages.log"; ACTION=upgrade-node; YES=true; supported_os_codename() { printf noble; }; '
MOCK = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
operation=next(x for x in args if x in ('update','upgrade','install'))
root=Path(os.environ['PACKAGE_FIXTURE'])
with (root/'calls').open('a') as output:
 output.write(json.dumps({'operation':operation,'args':args,'tty':[os.isatty(x) for x in range(3)],'frontend':os.environ.get('DEBIAN_FRONTEND'),'restart':os.environ.get('NEEDRESTART_MODE')})+'\\n')
if operation=='update':sys.exit(int(os.environ.get('PACKAGE_UPDATE_STATUS','0')))
if '--simulate' in args:
 print(os.environ.get('PACKAGE_PLAN_TEXT','Inst console-setup [1] (2 fixture)' if os.environ.get('PACKAGE_PENDING')=='1' else '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.'))
 sys.exit(int(os.environ.get('PACKAGE_PLAN_STATUS','0')))
if '-y' not in args and '--assume-yes' not in args:
 print('Do you want to continue? [Y/n] ',end='',flush=True)
 sys.exit(45)
if os.environ.get('PACKAGE_QUESTIONS')=='1':
 for prompt in ('Encoding to use on the console: ','Character set to support: ','Keep existing configuration: '):
  print(prompt,end='',flush=True)
  answer=sys.stdin.readline()
  if not answer:sys.exit(44)
  with (root/'answers').open('a') as output:output.write(answer)
sys.exit(int(os.environ.get('PACKAGE_UPGRADE_STATUS','0')))
'''


class SystemPackageTests(unittest.TestCase):
    terminal = test_input.InputWorkflowTests.terminal

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remnacust-package-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        tools = self.root / 'bin'
        tools.mkdir()
        (tools / 'apt-get').write_text(MOCK)
        (tools / 'apt-get').chmod(0o755)
        self.previous = dict(os.environ)
        os.environ.update(PACKAGE_FIXTURE=str(self.root), REMNACUST_ROOT=str(self.root / 'installation'),
                          PATH=str(tools) + os.pathsep + os.environ['PATH'])
        for name in ('PACKAGE_PENDING', 'PACKAGE_QUESTIONS', 'PACKAGE_UPDATE_STATUS', 'PACKAGE_UPGRADE_STATUS',
                     'PACKAGE_PLAN_TEXT', 'PACKAGE_PLAN_STATUS', 'REMNACUST_UPDATE_JOB'):
            os.environ.pop(name, None)
        self.addCleanup(self.restore_environment)

    def restore_environment(self):
        os.environ.clear()
        os.environ.update(self.previous)

    def run_shell(self, command):
        return subprocess.run(['bash', '-c', command, 'test', str(INSTALLER), str(self.root)],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)

    def calls(self):
        path = self.root / 'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_terminal_displays_questions_and_reads_operator_answers_even_with_yes(self):
        os.environ['PACKAGE_QUESTIONS'] = '1'
        os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
        code, output = self.terminal(SETUP + 'update_system_packages; printf ACTION-CONTINUED', [
            ('Encoding to use on the console: ', '27\n'),
            ('Character set to support: ', '6\n'),
            ('Keep existing configuration: ', 'retain-personal-value\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('ACTION-CONTINUED', output)
        self.assertEqual((self.root / 'answers').read_text(), '27\n6\nretain-personal-value\n')
        self.assertNotIn('retain-personal-value', (self.root / 'packages.log').read_text())
        for call in self.calls():
            self.assertEqual(call['tty'], [True, True, True])
            self.assertEqual(call['frontend'], 'readline')
            self.assertEqual(call['restart'], 'i')
            self.assertIn('-y', call['args'])
            self.assertNotIn('APT::Get::Assume-Yes=false', call['args'])
            self.assertNotIn('--assume-no', call['args'])
        self.assertEqual([c['operation'] for c in self.calls()], ['update', 'upgrade'])
        self.assertIn('--with-new-pkgs', self.calls()[1]['args'])

    def test_terminal_eof_stops_before_action(self):
        os.environ['PACKAGE_QUESTIONS'] = '1'
        code, output = self.terminal(SETUP + 'update_system_packages; printf UNEXPECTED-ACTION', [
            ('Encoding to use on the console: ', b'\x04')])
        self.assertEqual(code, 44, output)
        self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_logged_terminal_keeps_package_questions_and_excludes_answers(self):
        os.environ['PACKAGE_QUESTIONS'] = '1'
        command = SETUP + 'ROOT="$2/install-root"; start_operation_log; update_system_packages; printf ACTION-CONTINUED'
        answers = ['private-console-answer', 'private-charset-answer', 'private-config-answer']
        code, output = self.terminal(command, list(zip(
            ['Encoding to use on the console: ', 'Character set to support: ', 'Keep existing configuration: '],
            [answer + '\n' for answer in answers])))
        self.assertEqual(code, 0, output)
        log = (self.root / 'install-root/logs/installer-node.log').read_text()
        self.assertIn('Encoding to use on the console', log)
        self.assertIn('APT upgrade: exit 0', log)
        for answer in answers:
            self.assertNotIn(answer, log)
        self.assertTrue(all(call['tty'] == [True, True, True] for call in self.calls()))

    def test_failed_index_update_prevents_upgrade_and_action(self):
        os.environ['PACKAGE_UPDATE_STATUS'] = '37'
        result = self.run_shell(SETUP + 'update_system_packages; printf UNEXPECTED-ACTION')
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertNotIn('UNEXPECTED-ACTION', result.stdout)
        self.assertEqual([c['operation'] for c in self.calls()], ['update'])
        self.assertIn('APT::Update::Error-Mode=any', self.calls()[0]['args'])

    def test_failed_upgrade_prevents_action_even_inside_conditional(self):
        os.environ['PACKAGE_UPGRADE_STATUS'] = '41'
        result = self.run_shell(SETUP + 'if update_system_packages; then printf UNEXPECTED-ACTION; else exit $?; fi')
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertNotIn('UNEXPECTED-ACTION', result.stdout)

    def test_unattended_pending_packages_request_ssh_without_applying_changes(self):
        os.environ['PACKAGE_PENDING'] = '1'
        result = self.run_shell(SETUP + 'update_system_packages; printf UNEXPECTED-ACTION')
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn('SSH', result.stderr)
        self.assertNotIn('UNEXPECTED-ACTION', result.stdout)
        self.assertEqual([c['operation'] for c in self.calls()], ['update', 'upgrade'])
        self.assertIn('--simulate', self.calls()[1]['args'])

    def test_unattended_current_system_can_continue_without_default_answers(self):
        result = self.run_shell(SETUP + 'update_system_packages; printf ACTION-CONTINUED')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ACTION-CONTINUED', result.stdout)
        self.assertIn('✓ Обновление системных пакетов\n', result.stdout)
        self.assertNotIn('автоматическим подтверждением', result.stdout)
        self.assertEqual([c['operation'] for c in self.calls()], ['update', 'upgrade', 'upgrade'])
        self.assertIn('--simulate', self.calls()[1]['args'])
        self.assertTrue(all('-y' in call['args'] and '--assume-no' not in call['args'] for call in self.calls()))

    def test_unattended_configuration_and_unknown_plans_never_apply(self):
        for plan in ('Conf console-setup (2 fixture)', 'Remv obsolete-package [1]', 'Unknown plan', ''):
            with self.subTest(plan=plan):
                (self.root / 'calls').unlink(missing_ok=True)
                os.environ['PACKAGE_PLAN_TEXT'] = plan
                result = self.run_shell(SETUP + 'update_system_packages; printf UNEXPECTED-ACTION')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertNotIn('UNEXPECTED-ACTION', result.stdout)
                self.assertEqual(len(self.calls()), 2)
                self.assertIn('--simulate', self.calls()[-1]['args'])

    def test_failed_simulation_stops_without_actual_upgrade(self):
        os.environ['PACKAGE_PLAN_STATUS'] = '38'
        result = self.run_shell(SETUP + 'update_system_packages; printf UNEXPECTED-ACTION')
        self.assertEqual(result.returncode, 38, result.stderr)
        self.assertNotIn('UNEXPECTED-ACTION', result.stdout)
        self.assertEqual(len(self.calls()), 2)

    def test_initial_package_events_do_not_skip_release_download_stages(self):
        result = self.run_shell(SETUP + 'report_update_progress() { printf "%s\\n" "$1" >> "$WORK/stages"; }; update_system_packages')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set((self.root / 'stages').read_text().splitlines()), {'checking'})

    def test_help_and_invalid_arguments_never_update_packages(self):
        for argument, expected in (('--help', 0), ('--unknown-argument', 1)):
            result = self.run_shell(SETUP + 'main ' + argument)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(self.calls(), [])

    def test_release_check_never_calls_apt_even_with_pending_kernel_or_package_errors(self):
        os.environ.update(PACKAGE_PENDING='1', PACKAGE_UPDATE_STATUS='37')
        result = self.run_shell(SETUP + 'ACTION=--check-release; update_system_packages; printf ACTION-CONTINUED')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ACTION-CONTINUED', result.stdout)
        self.assertEqual(self.calls(), [])

    def test_background_panel_upgrade_defers_os_maintenance_without_simulation_or_answers(self):
        job = '11111111-1111-4111-8111-111111111111'
        os.environ.update(REMNACUST_UPDATE_JOB=job,
                          REMNACUST_RELEASE_ENTRY_FILE=str(self.root / 'installation/control' / ('release-' + job + '.sh')),
                          PACKAGE_PENDING='1', PACKAGE_QUESTIONS='1', PACKAGE_UPDATE_STATUS='37')
        result = self.run_shell(SETUP + 'ACTION=upgrade-panel; report_update_progress() { printf "%s\\n" "$2" >> "$WORK/stages"; }; update_system_packages; printf ACTION-CONTINUED')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ACTION-CONTINUED', result.stdout)
        self.assertIn('Обслуживание ОС отложено', result.stdout)
        self.assertIn('отложено до SSH', (self.root / 'stages').read_text())
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / 'answers').exists())

    def test_background_marker_without_matching_verified_entry_does_not_bypass_cli_package_policy(self):
        os.environ.update(REMNACUST_UPDATE_JOB='11111111-1111-4111-8111-111111111111',
                          REMNACUST_RELEASE_ENTRY_FILE='/unrelated/entry.sh', PACKAGE_PENDING='1')
        result = self.run_shell(SETUP + 'ACTION=upgrade-panel; update_system_packages')
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual([c['operation'] for c in self.calls()], ['update', 'upgrade'])

    def test_background_context_retains_os_validation_and_terminal_questions(self):
        job = '11111111-1111-4111-8111-111111111111'
        os.environ.update(REMNACUST_UPDATE_JOB=job,
                          REMNACUST_RELEASE_ENTRY_FILE=str(self.root / 'installation/control' / ('release-' + job + '.sh')),
                          PACKAGE_QUESTIONS='1')
        result = self.run_shell(SETUP + 'ACTION=upgrade-panel; supported_os_codename() { return 19; }; update_system_packages')
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(self.calls(), [])
        code, output = self.terminal(SETUP + 'ACTION=upgrade-panel; update_system_packages; printf ACTION-CONTINUED', [
            ('Encoding to use on the console: ', '27\n'),
            ('Character set to support: ', '6\n'),
            ('Keep existing configuration: ', 'retain-value\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('ACTION-CONTINUED', output)
        self.assertEqual([c['operation'] for c in self.calls()], ['update', 'upgrade'])

    def test_dry_run_and_unsupported_host_do_not_change_packages(self):
        result = self.run_shell(SETUP + 'DRY_RUN=true; update_system_packages')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        result = self.run_shell(SETUP + 'supported_os_codename() { return 19; }; update_system_packages')
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(self.calls(), [])

    @unittest.skipUnless(os.geteuid() == 0, 'Dispatcher enforces root')
    def test_all_public_actions_update_packages_before_dispatch(self):
        setup = '''source "$1";
supported_os_codename() { printf noble; }
component_installed() { return 0; }
assert_fresh_target() { :; }
installed_helper() { :; }
lock_operation() { :; }
resolve_release() { printf v1.2.122; }
fetch_source() { :; }
python3() { printf ACTION-CONTINUED; }
for function in service_action deploy subscription_page_action manage_component_action cleanup_backups_action migrate_marzban; do
 eval "$function() { printf ACTION-CONTINUED; }"
done
main "$3" --yes
'''
        actions = ['install-panel', 'install-node', 'upgrade-panel', 'upgrade-node', 'migrate-remnawave-panel',
                   'migrate-remnawave-node', 'migrate-marzban-panel', 'install-subscription-page',
                   'upgrade-subscription-page', 'configure-subscription-page', 'manage-subscription-page',
                   'uninstall-subscription-page', 'uninstall-panel', 'uninstall-node', 'change-domain',
                   'show-config', 'status', 'logs', 'start', 'stop', 'restart', 'backup-panel', 'restore-panel',
                   'renew-node-certificate', 'renew-panel-certificate', 'check-panel', 'cleanup-backups', 'normalize-layout', '--check-release']
        for action in actions:
            with self.subTest(action=action):
                (self.root / 'calls').unlink(missing_ok=True)
                result = subprocess.run(['bash', '-c', setup, 'test', str(INSTALLER), str(self.root), action],
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([c['operation'] for c in self.calls()], [] if action == '--check-release' else ['update', 'upgrade', 'upgrade'])
                self.assertIn('Выпуск v1.2.122 проверен' if action == '--check-release' else 'ACTION-CONTINUED', result.stdout)


if __name__ == '__main__':
    unittest.main()
