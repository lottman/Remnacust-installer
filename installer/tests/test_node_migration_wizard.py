import json
from pathlib import Path
import subprocess
import unittest

import test_input


class NodeMigrationWizardTests(unittest.TestCase):
    setUp = test_input.InputWorkflowTests.setUp
    terminal = test_input.InputWorkflowTests.terminal
    def command(self, state=None):
        (self.root / 'node.json').write_text(json.dumps(state or {'apiPort': 7289}))
        return ('source "$1"; WORK="$2"; STATE="$2/node.json"; ACTION=migrate-remnawave-node; '
                'COMPONENT=node; HELPER="$(dirname "$1")/runtime.py"; '
                'certificate_preflight() { printf CERTIFICATE-CHECKED; }; dns_preflight() { printf DNS-CHECKED; }; ')

    def test_migration_asks_for_xhttp_and_certificate_with_existing_api_port(self):
        command = self.command() + ('TLS_METHOD=existing; CERT_FILE=/fixture/cert.pem; KEY_FILE=/fixture/key.pem; '
                                   'node_migration_wizard; printf "RESULT=%s|%s|%s" "$PORT" "$NODE_DOMAIN" "$NODE_MIGRATION_TLS"')
        code, output = self.terminal(command, [
            ('IP/CIDR главного сервера: все входящие порты кроме SSH только от него (Enter — свой firewall): ', '\n'),
            ('Настроить TLS/XHTTP на ноде? y/n [n]: ', 'y\n'),
            ('Домен ноды: ', 'edge.example.com\n'),
            ('Использовать домен edge.example.com? y/n [y]: ', '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=7289|edge.example.com|true', output)
        self.assertIn('CERTIFICATE-CHECKED', output)
        self.assertNotIn('Порт API ноды [', output)
        self.assertNotIn('SECRET_KEY', output)

    def test_declining_xhttp_keeps_credentials_and_existing_port(self):
        before = self.command()
        data = (self.root / 'node.json').read_bytes()
        code, output = self.terminal(before + 'node_migration_wizard; printf "RESULT=%s|%s" "$PORT" "$NODE_MIGRATION_TLS"', [
            ('IP/CIDR главного сервера: все входящие порты кроме SSH только от него (Enter — свой firewall): ', '\n'),
            ('Настроить TLS/XHTTP на ноде? y/n [n]: ', 'n\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=7289|false', output)
        self.assertEqual((self.root / 'node.json').read_bytes(), data)
        self.assertNotIn('CERTIFICATE-CHECKED', output)

    def test_existing_managed_tls_can_be_kept(self):
        command = self.command({'apiPort': 7289, 'nodeDomain': 'kept.example.com'})
        code, output = self.terminal(command + 'node_migration_wizard; printf "TLS=%s" "$NODE_MIGRATION_TLS"', [
            ('TLS/XHTTP уже настроен для kept.example.com. Изменить настройки? y/n [n]: ', 'n\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('TLS=false', output)
        self.assertNotIn('Домен ноды:', output)

    def test_yes_mode_preserves_existing_tls_without_questions(self):
        command = self.command({'apiPort': 7289, 'nodeDomain': 'kept.example.com'})
        code, output = self.terminal(command + 'YES=true; node_migration_wizard; printf "PORT=%s" "$PORT"', [])
        self.assertEqual(code, 0, output)
        self.assertIn('PORT=7289', output)
        self.assertNotIn('y/n', output)

    def test_tls_failure_after_migration_is_not_reported_as_complete(self):
        command = self.command() + ('NODE_MIGRATION_TLS=true; NODE_DOMAIN=edge.example.com; '
                                    'manage_component_action() { return 31; }; '
                                    'if node_migration_finish; then printf FALSE-SUCCESS; fi')
        result = subprocess.run(['bash', '-c', command, 'test', str(test_input.INSTALLER), str(self.root)], capture_output=True, text=True)
        self.assertNotIn('FALSE-SUCCESS', result.stdout)
        self.assertIn('Перенос ноды завершён, но настройка TLS/XHTTP не завершена', result.stderr)


if __name__ == '__main__':
    unittest.main()
