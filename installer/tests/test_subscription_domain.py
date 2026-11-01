import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import subscription_domain as domain


class SubscriptionDomainTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.directory = self.root / 'panel'
        self.directory.mkdir()
        self.env = self.directory / '.env'
        runtime.write(self.env, '# preserved\nAPP_SECRET=private-sentinel\nSUB_PUBLIC_DOMAIN="https://old.example.test/api/sub" # saved\n')
        self.compose = self.directory / 'docker-compose.yml'
        runtime.write(self.compose, {'services': {
            'api': {'image': 'panel:fixed', 'env_file': ['.env'], 'environment': ['SUB_PUBLIC_DOMAIN=old.example.test/api/sub', 'OTHER=unchanged']},
            'worker': {'env_file': ['.env'], 'environment': {'SUB_PUBLIC_DOMAIN': 'old.example.test/api/sub'}},
            'database': {'environment': {'SUB_PUBLIC_DOMAIN': 'unrelated.example.test'}},
        }})
        runtime.write(self.root / 'registry/panel.json', {'component': 'panel', 'directory': str(self.directory),
            'applications': ['api', 'worker'], 'composeFiles': [str(self.compose)]})

    def test_read_and_bidirectional_writes_preserve_secrets_services_and_backups(self):
        before = domain.synchronize(self.root)
        self.assertEqual(before['value'], 'old.example.test/api/sub')
        after = domain.synchronize(self.root, {'value': 'new.example.test/client', 'expectedRevision': before['revision']})
        self.assertNotEqual(before['revision'], after['revision'])
        self.assertEqual(after['value'], 'new.example.test/client')
        self.assertNotIn('private-sentinel', json.dumps(after))
        self.assertIn('APP_SECRET=private-sentinel', self.env.read_text())
        config = runtime.load(self.compose)
        for service in ['api', 'worker']:
            self.assertEqual(config['services'][service]['environment']['SUB_PUBLIC_DOMAIN'], after['value'])
        self.assertEqual(config['services']['api']['environment']['OTHER'], 'unchanged')
        self.assertEqual(config['services']['database']['environment']['SUB_PUBLIC_DOMAIN'], 'unrelated.example.test')
        self.assertEqual(self.env.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(list((self.root / 'backups/panel').glob('subscription-domain-*/manifest.json'))), 1)
        domain.synchronize(self.root, {'value': after['value'], 'expectedRevision': after['revision']})
        self.assertEqual(len(list((self.root / 'backups/panel').glob('*'))), 1, 'idempotent writes must not grow backups')
        runtime.write(self.env, self.env.read_text().replace(after['value'], 'manual.example.test'))
        manual = domain.synchronize(self.root)
        self.assertEqual(manual['value'], 'manual.example.test')
        domain.synchronize(self.root, {'value': manual['value'], 'expectedRevision': manual['revision']})
        self.assertEqual(runtime.load(self.compose)['services']['worker']['environment']['SUB_PUBLIC_DOMAIN'], 'manual.example.test')

    def test_compare_and_swap_rejects_changes_to_any_environment_value(self):
        before = domain.synchronize(self.root)
        runtime.write(self.env, self.env.read_text() + 'NEW_SECRET=changed\n')
        with self.assertRaisesRegex(domain.DomainError, 'DOMAIN_CHANGED'):
            domain.synchronize(self.root, {'value': 'new.example.test', 'expectedRevision': before['revision']})
        self.assertIn('NEW_SECRET=changed', self.env.read_text())
        self.assertNotIn('new.example.test', self.compose.read_text())

    def test_input_cannot_choose_paths_keys_schemes_or_private_addresses(self):
        before = domain.synchronize(self.root)
        for value in ['https://user:secret@sub.example.test', 'http://sub.example.test', '127.0.0.1', '2130706433',
                      'sub.local', 'sub.example.test:8443', 'sub.example.test/../panel', 'sub.example.test\nAPP_SECRET=x',
                      'sub.example.test?secret=x', 'sub.example.test\\panel']:
            with self.subTest(value=value), self.assertRaises((ValueError, domain.DomainError)):
                domain.synchronize(self.root, {'value': value, 'expectedRevision': before['revision']})
        with self.assertRaisesRegex(domain.DomainError, 'DOMAIN_CHANGED'):
            domain.synchronize(self.root, {'value': 'sub.example.test', 'expectedRevision': before['revision'], 'path': '/etc/shadow'})

    def test_symlinks_hardlinks_and_nonregular_files_are_rejected(self):
        self.env.unlink()
        external = self.root / 'external'
        runtime.write(external, 'SUB_PUBLIC_DOMAIN=private.example.test\n')
        self.env.symlink_to(external)
        with self.assertRaisesRegex(domain.DomainError, 'DOMAIN_UNSAFE_PATH'):
            domain.synchronize(self.root)
        self.env.unlink()
        os.link(external, self.env)
        with self.assertRaisesRegex(domain.DomainError, 'DOMAIN_UNSAFE_PATH'):
            domain.synchronize(self.root)
        self.env.unlink()
        os.mkfifo(self.env)
        with self.assertRaisesRegex(domain.DomainError, 'DOMAIN_UNSAFE_PATH'):
            domain.synchronize(self.root)

    def test_failure_restores_only_files_written_by_this_operation(self):
        before = domain.synchronize(self.root)
        old_env = self.env.read_bytes()
        write = runtime.write
        def fail(path, *args, **kwargs):
            if Path(path) == self.compose:
                raise OSError('private-host-detail')
            return write(path, *args, **kwargs)
        with patch.object(runtime, 'write', side_effect=fail), self.assertRaises(OSError):
            domain.synchronize(self.root, {'value': 'new.example.test', 'expectedRevision': before['revision']})
        self.assertEqual(self.env.read_bytes(), old_env)

    def test_active_installer_is_not_interrupted_and_no_docker_command_is_started(self):
        with (self.root / '.installer.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaisesRegex(domain.DomainError, 'UPDATE_BUSY'):
                domain.synchronize(self.root)


if __name__ == '__main__':
    unittest.main()
