import base64
import copy
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import tracemalloc
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import marzban


class RuntimeTests(unittest.TestCase):
    def test_large_backup_hashing_is_bounded_and_matches_sha256(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'database.dump';chunk=b'backup-fixture\0'*65536
            expected=hashlib.sha256()
            with p.open('wb') as stream:
                for _ in range(24):stream.write(chunk);expected.update(chunk)
            tracemalloc.start()
            try:
                self.assertEqual(runtime.file_sha256(p),expected.hexdigest())
                self.assertLess(tracemalloc.get_traced_memory()[1],4*1024*1024)
            finally:tracemalloc.stop()

    def test_backup_verifies_every_file_used_by_restore(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)
            for name,data in {'database.dump':'fixture','container.before.json':'[]','compose.before.json':'{}',
                              'state.before.json':'{"composeFiles":["compose.json"]}',
                              'env-files.json':'{"/original/.env":"env-file-0"}',
                              'original-0':'{}','env-file-0':'test-only'}.items():
                (p/name).write_text(data)
            runtime.backup_hashes(p);runtime.verify_backup(p)
            self.assertEqual((p/'SHA256SUMS').stat().st_mode&0o777,0o600)
            (p/'env-file-0').write_text('tampered')
            with self.assertRaises(ValueError):runtime.verify_backup(p)
            runtime.backup_hashes(p)
            manifest=(p/'SHA256SUMS').read_text()
            (p/'SHA256SUMS').write_text('\n'.join(row for row in manifest.splitlines() if not row.endswith('  env-file-0'))+'\n')
            with self.assertRaises(ValueError):runtime.verify_backup(p)

    def test_backup_rejects_links_and_duplicate_manifest_entries(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);(p/'outside').write_text('fixture')
            (p/'linked').symlink_to(p/'outside')
            with self.assertRaises(ValueError):runtime.backup_hashes(p)
            (p/'linked').unlink();runtime.backup_hashes(p)
            manifest=(p/'SHA256SUMS').read_text();(p/'SHA256SUMS').write_text(manifest+manifest)
            with self.assertRaises(ValueError):runtime.verify_backup(p)

    def test_all_writers_and_infrastructure(self):
        old = {'services': {
            'main': {'image': 'old', 'environment': {'APP_SECRET': '${APP_SECRET}'}, 'ports': ['127.0.0.1:3900:3000']},
            'worker': {'image': 'other', 'environment': {'INSTANCE_TYPE': 'processor'}, 'profiles': ['worker']},
            'remnawave-scheduler': {'image': 'third', 'environment': {'INSTANCE_TYPE': '${ROLE}'}},
            'db': {'image': 'postgres:17.6', 'volumes': ['db:/var/lib/postgresql/data']},
            'cache': {'image': 'valkey/valkey:8-alpine'}},
            'volumes': {'db': {'name': 'original-data'}}, 'networks': {'default': {'name': 'old-network'}}}
        inspect = {'Config': {'Labels': {'com.docker.compose.service': 'main'}}}
        expected = copy.deepcopy(old)
        for name in ['main', 'worker', 'remnawave-scheduler']:
            expected['services'][name]['image'] = 'new'
        actual, apps = runtime.transform(old, inspect, 'panel', 'new')
        self.assertEqual(actual, expected)
        self.assertEqual(apps, ['main', 'worker', 'remnawave-scheduler'])
        self.assertEqual(old['services']['main']['image'], 'old')

    def test_panel_upgrade_preserves_both_reverse_proxies(self):
        for proxy, image in [('caddy', 'caddy:2-alpine'), ('nginx', 'nginx:1.28-alpine')]:
            with self.subTest(proxy=proxy):
                old = {'services': {'main': {'image': 'remnawave/backend:3.4.4', 'environment': {}},
                    'processor': {'image': 'remnawave/backend:3.4.4', 'environment': {'INSTANCE_TYPE': 'processor'}},
                    proxy: {'image': image, 'environment': {'INSTANCE_TYPE': 'processor'},
                            'ports': ['80:80', '443:443'], 'volumes': ['./config:/etc/proxy:ro', 'certs:/certs'],
                            'networks': ['frontend'], 'restart': 'always'},
                    'db': {'image': 'postgres:17.6', 'environment': {'INSTANCE_TYPE': 'processor'}}},
                    'volumes': {'certs': {'external': True}}, 'networks': {'frontend': {'external': True}}}
                result, apps = runtime.transform(old, {'Config': {'Labels': {'com.docker.compose.service': 'main'}}}, 'panel', 'new')
                self.assertEqual(apps, ['main', 'processor'])
                self.assertEqual(result['services'][proxy], old['services'][proxy])
                self.assertEqual(result['services']['db'], old['services']['db'])
                self.assertEqual(result['networks'], old['networks'])
                self.assertEqual(result['volumes'], old['volumes'])

    def test_discovery_preserves_project_and_multiple_files(self):
        with tempfile.TemporaryDirectory(prefix='install with spaces ') as t:
            p = Path(t); (p/'a.yml').touch(); (p/'b.json').touch()
            c = {'Id': 'abc', 'Config': {'Env': ['APP_SECRET=original', 'DATABASE_URL=postgresql://db'], 'Labels': {
                'com.docker.compose.project': 'original-project', 'com.docker.compose.service': 'main',
                'com.docker.compose.project.working_dir': t, 'com.docker.compose.project.config_files': 'a.yml,b.json'}}}
            result = runtime.discover(c, 'panel')
            self.assertEqual(result['project'], 'original-project')
            self.assertEqual(result['composeFiles'], [str(p/'a.yml'), str(p/'b.json')])
            c['Config']['Labels']['com.docker.compose.project.config_files'] = '/missing'
            self.assertEqual(runtime.discover(c, 'panel', compose_file=str(p/'a.yml'))['composeFiles'], [str(p/'a.yml')])
            c['Config']['Env'] = ['DATABASE_URL=postgresql://db']
            with self.assertRaises(ValueError): runtime.discover(c, 'panel', compose_file=str(p/'a.yml'))

    def test_actual_roles_resolve_env_file_and_different_images(self):
        old = {'services': {'main': {'image': 'old'}, 'hidden-worker': {'image': 'worker-old', 'environment': {'INSTANCE_TYPE': '${ROLE}'}}}}
        main = {'Config': {'Labels': {'com.docker.compose.service': 'main'}}}
        worker = {'Config': {'Labels': {'com.docker.compose.service': 'hidden-worker'}, 'Env': ['INSTANCE_TYPE=processor']}}
        new, apps = runtime.transform(old, main, 'panel', 'new', [worker])
        self.assertEqual(apps, ['main', 'hidden-worker'])
        self.assertEqual(new['services']['hidden-worker']['image'], 'new')

    def test_defaults_have_matching_strong_secrets(self):
        text = runtime.panel_env('APP_SECRET=change_me\nPOSTGRES_PASSWORD=change_me\n', 'panel.example.com', '3000')
        values = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
        self.assertEqual(len(values['APP_SECRET']), 64)
        self.assertIn(values['POSTGRES_PASSWORD'], values['DATABASE_URL'])
        self.assertEqual(values['HWID_ENABLED_DEFAULT'], 'true')
        self.assertNotEqual(text, runtime.panel_env('', 'panel.example.com', '3000'))

    def test_node_secret_literal_and_validation(self):
        secret = base64.b64encode(json.dumps(dict.fromkeys(['caCertPem', 'jwtPublicKey', 'nodeCertPem', 'nodeKeyPem'], 'PEM')).encode()).decode()
        self.assertIn("SECRET_KEY='" + secret + "'", runtime.node_env(secret, '2222'))
        for invalid in ['', "a'", 'not a key', base64.b64encode(b'{}').decode()]:
            with self.assertRaises(ValueError): runtime.node_env(invalid, '2222')

    def test_fresh_is_scoped_and_panel_is_loopback(self):
        config, state = runtime.fresh('panel', '/opt/test', 'test-panel', 'app', 'panel.example.com')
        self.assertEqual(config['services']['remnawave']['ports'], ['127.0.0.1:3000:3000'])
        for service in ['remnawave-db', 'remnawave-redis']:
            self.assertNotIn('ports', config['services'][service])
        self.assertTrue(all('name' not in v for v in config['volumes'].values()))
        self.assertEqual(state['project'], 'test-panel')
        config, _ = runtime.fresh('node', '/opt/test', 'test-node', 'app', number=2222, node_domain='node.example.com')
        self.assertIn('/opt/test/run:/var/lib/remnacust/run', config['services']['remnanode']['volumes'])

    def test_changed_secrets_ports_mounts_are_rejected(self):
        original = {'Config': {'Env': ['APP_SECRET=old', 'NODE_PORT=72']}, 'Mounts': [{'Source': '/data', 'Destination': '/app', 'RW': True}], 'HostConfig': {'NetworkMode': 'host'}}
        runtime.compare_environment(original, copy.deepcopy(original))
        for field in ['secret', 'mount', 'network']:
            new = copy.deepcopy(original)
            if field == 'secret': new['Config']['Env'][0] = 'APP_SECRET=new'
            if field == 'mount': new['Mounts'][0]['Source'] = '/new'
            if field == 'network': new['HostConfig']['NetworkMode'] = 'new'
            with self.assertRaises(ValueError): runtime.compare_environment(original, new)

    def test_validation_rejects_injection(self):
        for value in ['https://example.com', 'a.com;rm', '../x', 'a.com/']:
            with self.assertRaises(ValueError): runtime.domain(value)
        for value in ['0', '65536', '-1', '22;id']:
            with self.assertRaises(ValueError): runtime.port(value)
        with self.assertRaises(ValueError): runtime.project_name('../data')

    def test_write_is_private_and_no_symlink(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)/'state.json'; runtime.write(p, {'ok': True})
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            alias = Path(t)/'alias'; alias.symlink_to(p)
            with self.assertRaises(ValueError): runtime.write(alias, 'changed')
            self.assertEqual(json.loads(p.read_text()), {'ok': True})


SQUAD = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa'
USER = {'username': 'alice', 'status': 'active', 'expire': 1800000000, 'created_at': '2026-01-01T12:00:00',
        'data_limit': 1000, 'used_traffic': 400, 'data_limit_reset_strategy': 'month',
        'proxies': {'vless': {'id': 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb'}, 'trojan': {'password': 'password-original'}},
        'subscription_url': 'https://source.example.com/sub/a-valid-short-uuid', 'note': 'Original note'}


class MarzbanTests(unittest.TestCase):
    def test_credentials_dates_and_remaining_quota(self):
        result, warnings = marzban.convert(USER, SQUAD)
        self.assertEqual(result['trafficLimitBytes'], 600)
        self.assertEqual(result['trafficLimitStrategy'], 'NO_RESET')
        self.assertEqual(result['trojanPassword'], 'password-original')
        self.assertEqual(result['vlessUuid'], USER['proxies']['vless']['id'])
        self.assertEqual(result['createdAt'], '2026-01-01T12:00:00Z')
        self.assertTrue(warnings)

    def test_on_hold_stays_disabled(self):
        user = dict(USER, status='on_hold', expire=0)
        result, warnings = marzban.convert(user, SQUAD)
        self.assertEqual(result['status'], 'DISABLED')
        self.assertEqual(result['expireAt'], '2099-12-31T23:59:59Z')
        self.assertTrue(any('ON_HOLD' in w for w in warnings))

    def test_exhausted_quota_never_becomes_unlimited(self):
        result, _ = marzban.convert(dict(USER, used_traffic=1001), SQUAD)
        self.assertEqual(result['status'], 'LIMITED')
        self.assertEqual(result['trafficLimitBytes'], 1)
        result, _ = marzban.convert(dict(USER, data_limit=0), SQUAD)
        self.assertEqual(result['trafficLimitBytes'], 0)

    def test_total_quota_preserves_reset_with_warning(self):
        result, warnings = marzban.convert(USER, SQUAD, 'total')
        self.assertEqual(result['trafficLimitBytes'], 1000)
        self.assertEqual(result['trafficLimitStrategy'], 'MONTH')
        self.assertTrue(any('starts at zero' in w for w in warnings))

    def test_no_silent_renaming_regeneration_or_activation(self):
        for user in [dict(USER, username='bad.name'), dict(USER, status='unknown'), dict(USER, proxies={'vmess': {'id': 'x'}}),
                     dict(USER, proxies={'trojan': {'password': 'short'}}), dict(USER, data_limit=-1)]:
            with self.assertRaises(marzban.MigrationError): marzban.convert(user, SQUAD)

    def test_subhash_is_optional_and_legacy_jwt_requires_page(self):
        result, _ = marzban.convert(USER, SQUAD, preserve_hash=True)
        self.assertEqual(result['shortUuid'], 'a-valid-short-uuid')
        with self.assertRaises(marzban.MigrationError): marzban.convert(dict(USER, subscription_url='https://a.com/sub/jwt.token.long'), SQUAD, preserve_hash=True)

    def test_existing_user_must_match_all_keys_and_squad(self):
        result, _ = marzban.convert(USER, SQUAD)
        self.assertTrue(marzban.matches(result, result))
        for field, value in [('vlessUuid', 'changed'), ('trojanPassword', 'changed'), ('status', 'ACTIVE2'), ('activeInternalSquads', [])]:
            changed = dict(result, **{field: value})
            self.assertFalse(marzban.matches(changed, result))

    def test_remote_http_credentials_and_redirects_rejected(self):
        for url in ['http://example.com', 'https://user:pass@example.com', 'https://example.com/?q=1']:
            with self.assertRaises(marzban.MigrationError): marzban.Api(url)
        marzban.Api('http://127.0.0.1:1234')
        with self.assertRaises(marzban.MigrationError): marzban.NoRedirect().redirect_request(None, None, 302, None, None, 'https://evil.com')

    def test_export_checks_stable_count_and_pagination(self):
        with tempfile.TemporaryDirectory() as t:
            class Fake:
                def request(self, *args): return {'total': 2, 'users': [USER]}
            with self.assertRaises(marzban.MigrationError): marzban.export_source(Fake(), Path(t), 1)

    def test_dry_run_and_conflicts_write_no_users(self):
        with tempfile.TemporaryDirectory() as t:
            events = []
            class Fake:
                def __init__(self, url, token=''): self.url = url
                def request(self, method, path, body=None, **kwargs):
                    events.append((self.url, method, path))
                    if path == '/api/admin/token': return {'access_token': 'secret'}
                    if path == '/api/internal-squads': return {'response': {'internalSquads': [{'uuid': SQUAD}]}}
                    if path.startswith('/api/users?'): return {'total': 1, 'users': [USER]}
                    if path.startswith('/api/users/by-username'): return None
                    raise AssertionError('Unexpected write')
            args = type('Args', (), dict(output=str(Path(t)/'report'), source_url='source', destination_url='dest', internal_squad=SQUAD,
                batch_size=100, quota_mode='remaining', preserve_subhash=False, dry_run=True, yes=True))()
            with patch.object(marzban, 'Api', Fake), patch.dict(os.environ, {'MARZBAN_USERNAME': 'a', 'MARZBAN_PASSWORD': 'secret', 'REMNACUST_API_TOKEN': 'token'}):
                marzban.run(args)
            self.assertFalse(any(host == 'dest' and method == 'POST' for host, method, _ in events))
            self.assertEqual((Path(t)/'report'/'marzban-export.json').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__': unittest.main()
