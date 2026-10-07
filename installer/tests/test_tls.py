import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tls


class CertificateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cert, self.key = self.create_pair('edge.example.com', 'good')

    def create_pair(self, hostname, name):
        cert, key = self.root/(name+'.pem'), self.root/(name+'.key')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '3',
                        '-subj', '/CN='+hostname, '-addext', 'subjectAltName=DNS:'+hostname],
                       check=True, capture_output=True)
        return cert, key

    def test_valid_ecdsa_certificate_copy_has_private_permissions(self):
        tls.copy_pair('edge.example.com', self.cert, self.key, self.root)
        self.assertEqual((self.root/'certs/privkey.pem').read_bytes(), self.key.read_bytes())
        self.assertEqual(stat.S_IMODE((self.root/'certs/privkey.pem').stat().st_mode), 0o600)

    def test_different_domain_is_rejected(self):
        with self.assertRaises(ValueError):
            tls.certificate_pair('other.example.com', self.cert, self.key)

    def test_wrong_private_key_preserves_old_pair(self):
        tls.copy_pair('edge.example.com', self.cert, self.key, self.root)
        before = (self.root/'certs/privkey.pem').read_bytes()
        _, wrong = self.create_pair('edge.example.com', 'wrong')
        with self.assertRaises(ValueError):
            tls.copy_pair('edge.example.com', self.cert, wrong, self.root)
        self.assertEqual(before, (self.root/'certs/privkey.pem').read_bytes())

    def test_certificate_near_expiration_is_rejected(self):
        result = subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                                 '-keyout', str(self.key), '-out', str(self.cert), '-days', '1',
                                 '-subj', '/CN=edge.example.com'], capture_output=True)
        self.assertEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            tls.certificate_pair('edge.example.com', self.cert, self.key)

    def test_wildcard_pair_covers_only_one_level(self):
        cert, key = self.create_pair('*.example.com', 'wildcard')
        tls.certificate_pair('edge.example.com', cert, key)
        with self.assertRaises(ValueError):
            tls.certificate_pair('deep.edge.example.com', cert, key)

    def test_copy_does_not_follow_destination_symlink(self):
        (self.root/'certs').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            tls.copy_pair('edge.example.com', self.cert, self.key, self.root)

    def test_credentials_reject_public_permissions_and_mismatched_provider(self):
        src=self.root/'credentials';dst=self.root/'private/dns.ini'
        src.write_text('dns_cloudflare_api_token = sample_token\n');src.chmod(0o644)
        with self.assertRaises(ValueError):
            tls.credentials('cloudflare', src, dst)
        src.chmod(0o600)
        with self.assertRaises(ValueError):
            tls.credentials('gcore', src, dst)
        tls.credentials('cloudflare', src, dst)
        self.assertEqual(stat.S_IMODE(dst.stat().st_mode), 0o600)
        self.assertEqual(src.read_bytes(), dst.read_bytes())

    def test_invalid_provider_content_is_not_echoed(self):
        src=self.root/'credentials';src.write_text('secret_token = do-not-echo\n');src.chmod(0o600)
        with self.assertRaises(ValueError) as caught:
            tls.credentials('cloudflare', src, self.root/'copy')
        self.assertNotIn('do-not-echo', str(caught.exception))

    def test_caddy_email_and_manual_pair_configuration(self):
        tls.caddy('edge.example.com', 'admin@example.com', 'auto', self.root)
        text=(self.root/'Caddyfile').read_text()
        self.assertIn('email admin@example.com', text)
        self.assertNotIn('privkey.pem', text)
        tls.caddy('edge.example.com', '', 'existing', self.root)
        self.assertIn('tls /var/lib/remnacust/tls/fullchain.pem', (self.root/'Caddyfile').read_text())
        with self.assertRaises(ValueError):
            tls.caddy('edge.example.com', 'admin@example.com\nadmin off', 'auto', self.root)

    def test_timer_quotes_script_path_and_systemd_specifiers(self):
        writes=[]
        with patch.object(tls, 'write', lambda p,v,mode: writes.append((str(p),v,mode))):
            tls.timer('remnacust-acme-fixture', '/opt/some path/100%/renew.sh')
        self.assertIn('ExecStart="/opt/some path/100%%/renew.sh"', writes[0][1])
        self.assertIn('Persistent=true', writes[1][1])


if __name__ == '__main__':
    unittest.main()
