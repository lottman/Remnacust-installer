import sys
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ufw_guard


class UfwTests(unittest.TestCase):
    def scenario(self, active=True, result=0, failure=None, missing=None):
        calls = []
        def which(name):
            return None if name == missing else '/usr/sbin/' + name
        def run(args):
            calls.append(args)
            if failure and failure(args):
                raise RuntimeError('fixture failure')
            return 'Status: active\n' if active else 'Status: inactive\n'
        def execute(args):
            calls.append(args)
            if isinstance(result, BaseException):
                raise result
            return result
        return calls, lambda: ufw_guard.guarded(['/certbot', 'certonly'], Path('/fixture'), run, execute, which, lambda *_: lambda: None)

    def test_active_firewall_is_armed_disabled_restored_and_timer_cancelled(self):
        calls, execute = self.scenario()
        self.assertEqual(execute(), 0)
        self.assertEqual([row[1:] for row in calls if row[0].endswith('/ufw')], [['status'], ['--force', 'disable'], ['--force', 'enable'], ['status']])
        self.assertIn('--on-active=10m', calls[1])
        self.assertEqual(calls[3], ['/certbot', 'certonly'])
        self.assertTrue(calls[-1][-1].endswith('.timer'))

    def test_inactive_and_absent_firewalls_remain_unchanged(self):
        for options in ({'active': False}, {'missing': 'ufw'}):
            calls, execute = self.scenario(**options)
            self.assertEqual(execute(), 0)
            self.assertFalse(any('--force' in row for row in calls))

    def test_failed_and_interrupted_certbot_restore_firewall(self):
        for result in (7, KeyboardInterrupt()):
            calls, execute = self.scenario(result=result)
            if isinstance(result, BaseException):
                with self.assertRaises(KeyboardInterrupt):
                    execute()
            else:
                self.assertEqual(execute(), 7)
            self.assertEqual(calls[-3][1:], ['--force', 'enable'])

    def test_recovery_must_be_armed_before_disabling(self):
        for options in ({'missing': 'systemd-run'}, {'failure': lambda args: args[0].endswith('systemd-run')}):
            calls, execute = self.scenario(**options)
            with self.assertRaises(RuntimeError):
                execute()
            self.assertFalse(any('disable' in row for row in calls))

    def test_failure_to_restore_keeps_watchdog_and_fails_operation(self):
        calls, execute = self.scenario(failure=lambda args: args[0].endswith('/ufw') and args[-1] == 'enable')
        with self.assertRaises(RuntimeError):
            execute()
        self.assertFalse(any(row[0].endswith('systemctl') for row in calls))

    def test_reboot_recovery_is_persisted_before_the_firewall_can_be_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / 'marker'
            unit = Path(directory) / 'restore.service'
            calls = []
            disarm = ufw_guard.reboot_recovery('/usr/sbin/ufw', '/usr/bin/systemctl', lambda args: calls.append(args), folder, unit)
            self.assertTrue((folder / 'required').is_file())
            self.assertIn('ConditionPathExists=' + str(folder / 'required'), unit.read_text())
            self.assertIn('ExecStart="/usr/sbin/ufw" --force enable', unit.read_text())
            self.assertEqual(calls[-1], ['/usr/bin/systemctl', 'enable', 'restore.service'])
            disarm()
            self.assertFalse((folder / 'required').exists())

    def test_interruption_terminates_certbot_before_restoring_firewall(self):
        child = Mock()
        child.wait.side_effect = [KeyboardInterrupt(), 0]
        with patch.object(ufw_guard.subprocess, 'Popen', return_value=child):
            with self.assertRaises(KeyboardInterrupt):
                ufw_guard.run_certificate(['/certbot'])
        child.terminate.assert_called_once()


if __name__ == '__main__':
    unittest.main()
