import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from test_input import INSTALLER, InputWorkflowTests


class BackupPasswordTests(unittest.TestCase):
    terminal = InputWorkflowTests.terminal

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remnacust-backup-setup-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_generated_password_is_private_and_not_echoed(self):
        code, output = self.terminal('source "$1"; WORK="$2"; backup_password_wizard',
                                     [('Пароль резервных копий: ', '\n')])
        self.assertEqual(code, 0, output)
        file = self.root / 'backup-password.txt'
        password = file.read_text()
        self.assertGreaterEqual(len(password), 32)
        self.assertNotIn(password, output)
        self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)

    def test_mismatch_and_invalid_password_return_to_prompt(self):
        password = 'Backup-password-123456789!'
        code, output = self.terminal('source "$1"; WORK="$2"; backup_password_wizard', [
            ('Пароль резервных копий: ', 'short\n'), ('Повторите пароль: ', 'short\n'),
            ('Пароль резервных копий: ', password + '\n'), ('Повторите пароль: ', 'different\n'),
            ('Пароль резервных копий: ', password + '\n'), ('Повторите пароль: ', password + '\n')])
        self.assertEqual(code, 0, output)
        self.assertEqual((self.root / 'backup-password.txt').read_text(), password)
        self.assertNotIn(password, output)
        self.assertIn('Пароли не совпадают', output)

    def test_end_of_input_stops_without_spam_or_partial_password(self):
        code, output = self.terminal('source "$1"; WORK="$2"; backup_password_wizard',
                                     [('Пароль резервных копий: ', b'\x04')])
        self.assertEqual(code, 1, output)
        self.assertFalse((self.root / 'backup-password.txt').exists())

    def test_spaces_are_rejected_instead_of_silently_trimming_password(self):
        password = ' Leading-backup-123456!'
        code, output = self.terminal('source "$1"; WORK="$2"; backup_password_wizard', [
            ('Пароль резервных копий: ', password + '\n'), ('Повторите пароль: ', password + '\n'),
            ('Пароль резервных копий: ', '\n')])
        self.assertEqual(code, 0, output)
        self.assertNotEqual((self.root / 'backup-password.txt').read_text(), password.strip())
        self.assertIn('без пробелов', output)

    def test_unattended_password_and_invalid_environment(self):
        for password in ['Configured-backup-12345!', '', 'short', 'contains spaces and text']:
            with self.subTest(password='valid' if len(password) >= 16 else 'empty-or-short'):
                result = subprocess.run(['bash', '-c', 'source "$1"; WORK="$2"; backup_password_wizard',
                    'test', str(INSTALLER), str(self.root)], stdin=subprocess.DEVNULL,
                    capture_output=True, text=True, timeout=5,
                    env={**os.environ, 'REMNACUST_BACKUP_PASSWORD': password})
                file = self.root / 'backup-password.txt'
                valid = not password or (len(password) >= 16 and ' ' not in password)
                self.assertEqual(result.returncode == 0, valid)
                self.assertEqual(file.exists(), valid)
                if valid:
                    self.assertNotIn(file.read_text(), result.stdout + result.stderr)
                    file.unlink()


if __name__ == '__main__':
    unittest.main()
