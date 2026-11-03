import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'


class OperationLogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / 'logs/installer-node.log'

    def command(self, body):
        return ['bash', '-c', 'source "$1"; ROOT="$2"; ACTION=upgrade-node; start_operation_log; ' + body,
                'test', str(INSTALLER), str(self.root)]

    def run_action(self, body):
        return subprocess.run(self.command(body), capture_output=True, text=True, timeout=10)

    def test_success_retains_private_log_and_next_action_replaces_it(self):
        first = self.run_action('step "Download fixture" bash -c "printf fixture-first"; printf SECRET_STDOUT; info ready')
        self.assertEqual(first.returncode, 0, first.stderr)
        data = self.log.read_text()
        self.assertIn('fixture-first', data)
        self.assertIn('FINISH action=upgrade-node exit=0', data)
        self.assertNotIn('SECRET_STDOUT', data)
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.log.parent.stat().st_mode & 0o777, 0o700)
        second = self.run_action('info second-action')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn('fixture-first', self.log.read_text())
        self.assertIn('second-action', self.log.read_text())

    def test_failed_step_keeps_output_status_context_and_path(self):
        result = self.run_action('step "Failed fixture" bash -c "echo precise-failure >&2; exit 23"')
        self.assertEqual(result.returncode, 23)
        data = self.log.read_text()
        self.assertIn('precise-failure', data)
        self.assertIn('exit=23', data)
        self.assertIn('functions=', data)
        self.assertIn(str(self.log), result.stderr)

    def test_failure_before_deployment_and_direct_stderr_are_retained(self):
        result = self.run_action('printf "direct-failure\\n" >&2; die "validation-failure"')
        self.assertEqual(result.returncode, 1)
        self.assertIn('direct-failure', self.log.read_text())
        self.assertIn('validation-failure', self.log.read_text())
        self.assertIn(str(self.log), result.stderr)

    def test_signal_preserves_journal_and_prints_its_location(self):
        process = subprocess.Popen(self.command('info waiting; while :; do sleep .1; done'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and (not self.log.exists() or 'waiting' not in self.log.read_text()):
                time.sleep(.02)
            process.send_signal(signal.SIGTERM)
            _, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            self.assertIn('signal=TERM', self.log.read_text())
            self.assertIn(str(self.log), error)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_parallel_action_does_not_erase_active_log(self):
        process = subprocess.Popen(self.command('info active-operation; while :; do sleep .1; done'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and (not self.log.exists() or 'active-operation' not in self.log.read_text()):
                time.sleep(.02)
            result = self.run_action('info competing-operation')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('active-operation', self.log.read_text())
            self.assertNotIn('competing-operation', self.log.read_text())
        finally:
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)

    def test_symlink_directory_is_rejected_without_changing_target(self):
        target = self.root / 'other'
        target.mkdir()
        (self.root / 'logs').symlink_to(target, target_is_directory=True)
        result = self.run_action('true')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(target.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
