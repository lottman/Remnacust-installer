import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import management as manage
import runtime
import subscription_pages as pages


class ManagementTests(unittest.TestCase):
    def test_standalone_website_listens_on_selected_port_without_proxy_protocol(self):
        config = runtime.nginx_config('edge.example.test', 4433)
        self.assertIn('listen 0.0.0.0:4433 ssl;', config)
        self.assertIn('listen [::]:4433 ssl;', config)
        self.assertIn('listen unix:/var/lib/remnacust/run/nginx.sock ssl proxy_protocol;', config)
        self.assertNotIn('4433 ssl proxy_protocol', config)
        with self.assertRaises(ValueError): runtime.nginx_config('edge.example.test', '443;bad')

    def test_standalone_ports_are_recorded_and_must_be_distinct(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='7289', node_domain='edge.example.test', node_site_mode='standalone', node_site_port='4433', node_inbound_port='8444')
        self.assertEqual((state['apiPort'], state['nodeSitePort'], state['nodeInboundPort']), (7289, 4433, 8444))
        with self.assertRaises(ValueError):
            runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='4433', node_site_mode='standalone', node_site_port='4433')

    def test_first_node_standalone_domain_preserves_api_and_sets_public_site_port(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='7289')
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(self.root / 'registry/node.json', state)
        plan = runtime.load(manage.prepare(self.root, 'node', 'edge.example.test', tls_method='http', site_mode='standalone', site_port='4433', inbound_port='8444'))
        record = plan['records'][str(self.root / 'registry/node.json')]
        self.assertEqual((record['nodeSiteMode'], record['nodeSitePort'], record['nodeInboundPort'], record['apiPort']), ('standalone', 4433, 8444, 7289))
        self.assertIn('listen 0.0.0.0:4433 ssl;', plan['files'][str(directory / 'nginx.conf')]['after'])
        self.assertEqual(plan['siteFirewall'], {'before': 0, 'after': 4433})

    def test_prepare_cli_firewall_default_and_opt_out_use_real_plans(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='7289')
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(self.root / 'registry/node.json', state)
        for flags in ([], ['--no-firewall']):
            with self.subTest(flags=flags):
                argv = ['management.py', 'prepare', '--root', str(self.root), '--component', 'node',
                        '--domain', 'new.example.test', '--site-mode', 'standalone', '--site-port', '4433', *flags]
                with patch.object(sys, 'argv', argv), patch('sys.stdout', new_callable=io.StringIO) as output:
                    manage.main()
                plan = runtime.load(Path(output.getvalue().strip()))
                if flags:
                    self.assertNotIn('siteFirewall', plan)
                else:
                    self.assertEqual(plan['siteFirewall'], {'before': 0, 'after': 4433})

    def test_no_firewall_is_restricted_to_node_prepare(self):
        for operation in ('prepare', 'apply', 'complete', 'rollback', 'stop-proxy', 'info'):
            for component in ('node', 'panel', 'subscription-page', None):
                if operation == 'prepare' and component == 'node':
                    continue
                with self.subTest(operation=operation, component=component):
                    argv = ['management.py', operation, '--root', str(self.root), '--no-firewall']
                    if component:
                        argv += ['--component', component]
                    with patch.object(sys, 'argv', argv), patch('sys.stderr', new_callable=io.StringIO), \
                            patch.object(manage, 'prepare') as prepare, patch.object(manage, 'dispatch') as dispatch, \
                            patch.object(manage, 'description') as description:
                        with self.assertRaises(SystemExit) as error:
                            manage.main()
                    self.assertEqual(error.exception.code, 2)
                    prepare.assert_not_called()
                    dispatch.assert_not_called()
                    description.assert_not_called()

    def test_no_firewall_prepare_apply_and_rollback_never_manage_host_firewall(self):
        for outcome in ('complete', 'rollback', 'startup-failure', 'https-failure', 'rollback-failure'):
            with self.subTest(outcome=outcome):
                directory = self.root / outcome; directory.mkdir()
                config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='7289')
                runtime.write(directory / 'docker-compose.yml', config)
                runtime.write(directory / '.env', 'SECRET_KEY=fixture\nNODE_PORT=7289\n')
                runtime.write(self.root / 'registry/node.json', state)
                with patch.object(manage, 'set_site_firewall') as firewall, \
                        patch.object(manage.tls, 'copy_pair'), patch('node_site.install_site'), \
                        patch.object(runtime, 'wait_node_https') as https, \
                        patch.object(manage.subprocess, 'run', side_effect=AssertionError('unexpected host command')):
                    plan = manage.prepare(self.root, 'node', 'new.example.test', site_mode='standalone',
                                          site_port='4433', manage_firewall=False)
                    self.assertNotIn('siteFirewall', runtime.load(plan))
                    certificate, key = self.root / 'leaf.pem', self.root / 'key.pem'
                    if outcome == 'startup-failure':
                        with patch.object(pages, 'ready', side_effect=[RuntimeError('startup failed'), None]):
                            with self.assertRaisesRegex(RuntimeError, 'startup failed'):
                                manage.apply(plan, certificate, key)
                    else:
                        manage.apply(plan, certificate, key)
                        self.assertEqual(runtime.load(plan)['phase'], 'applied')
                        self.assertTrue(any('up' in row and 'node-nginx' in row for row in self.calls))
                        if outcome == 'complete':
                            manage.complete(plan)
                        elif outcome == 'https-failure':
                            https.side_effect = ValueError('HTTPS failed')
                            with self.assertRaisesRegex(ValueError, 'HTTPS failed'):
                                manage.complete(plan)
                        elif outcome == 'rollback-failure':
                            with patch.object(pages, 'ready', side_effect=RuntimeError('rollback failed')):
                                with self.assertRaisesRegex(RuntimeError, 'rollback failed'):
                                    manage.rollback(plan)
                        else:
                            manage.rollback(plan)
                    expected = 'complete' if outcome == 'complete' else 'applied' if outcome == 'rollback-failure' else 'rolled-back'
                    saved = runtime.load(plan)
                    self.assertEqual(saved['phase'], expected)
                    self.assertNotIn('siteFirewall', saved)
                    self.assertNotIn('siteFirewallApplied', saved)
                    firewall.assert_not_called()

    def test_standalone_firewall_and_proxy_roll_back_together(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='7289')
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / '.env', 'SECRET_KEY=fixture\nNODE_PORT=7289\n')
        runtime.write(self.root / 'registry/node.json', state)
        certificate, key = self.root / 'leaf.pem', self.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-keyout', str(key), '-out', str(certificate), '-days', '3', '-subj', '/CN=new.example.test', '-addext', 'subjectAltName=DNS:new.example.test'], capture_output=True, check=True)
        for failure in ('none', 'firewall', 'https'):
            plan = manage.prepare(self.root, 'node', 'new.example.test', site_mode='standalone', site_port='4433', inbound_port='8444')
            calls = []
            def firewall(port):
                calls.append(port)
                if failure == 'firewall' and port == 4433:
                    raise RuntimeError('fixture firewall failure')
            with patch.object(manage, 'set_site_firewall', side_effect=firewall):
                if failure == 'firewall':
                    with self.assertRaises(RuntimeError): manage.apply(plan, certificate, key)
                else:
                    manage.apply(plan, certificate, key)
                    self.assertIn('node-nginx', runtime.load(self.root / 'registry/node.json')['ownedServices'])
                    if failure == 'https':
                        with patch.object(runtime, 'wait_node_https', side_effect=ValueError('fixture HTTPS failure')):
                            with self.assertRaises(ValueError): manage.complete(plan)
                    else:
                        manage.rollback(plan)
            self.assertEqual(calls, [4433, 0])
            self.assertEqual(runtime.load(directory / 'docker-compose.yml'), config)
            self.assertEqual(runtime.load(self.root / 'registry/node.json'), state)

    def test_private_socket_directory_gains_only_search_access_and_can_be_restored(self):
        path = self.root / 'sockets'; path.mkdir(mode=0o700)
        private = path / 'node-reconciliation.json'; private.write_text('private fixture'); private.chmod(0o600)
        child = path / 'core-state'; child.mkdir(mode=0o700)
        access = manage.socket_access(path)
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        manage.apply_socket_access(access)
        self.assertEqual(path.stat().st_mode & 0o777, 0o711)
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)
        self.assertEqual(child.stat().st_mode & 0o777, 0o700)
        manage.apply_socket_access(access, restore=True)
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)

    def test_readable_private_files_prevent_socket_access_change(self):
        path = self.root / 'sockets'; path.mkdir(mode=0o700)
        public = path / 'configuration.json'; public.write_text('private fixture'); public.chmod(0o644)
        with self.assertRaises(ValueError): manage.socket_access(path)
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)

    def test_socket_directory_replacement_and_new_readable_files_are_rejected(self):
        path = self.root / 'sockets'; path.mkdir(mode=0o700)
        access = manage.socket_access(path)
        file = path / 'configuration.json'; file.write_text('fixture'); file.chmod(0o644)
        with self.assertRaises(ValueError): manage.apply_socket_access(access)
        file.unlink(); path.rename(self.root / 'previous-sockets'); path.mkdir(mode=0o700)
        with self.assertRaises(ValueError): manage.apply_socket_access(access)
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        env = patch.dict(os.environ, {'REMNACUST_ROOT': str(self.root)})
        env.start(); self.addCleanup(env.stop)
        self.directory = self.root / 'panel'; self.directory.mkdir()
        config, state = runtime.fresh('panel', self.directory, 'fixture', 'panel:1.1.7.61', hostname='old.example.test')
        state['version'] = '1.1.7.61'
        runtime.write(self.directory / 'docker-compose.yml', config)
        runtime.write(self.directory / 'Caddyfile', 'old.example.test {\n reverse_proxy remnawave:3000\n}\n')
        runtime.write(self.directory / '.env', 'APP_SECRET=UNCHANGED\nFRONT_END_DOMAIN=https://old.example.test\nPANEL_DOMAIN=old.example.test\nSUB_PUBLIC_DOMAIN=old.example.test/api/sub\n')
        self.state = state; self.config = config
        runtime.write(self.root / 'registry/panel.json', state)
        self.calls = []
        def command(base, *args):
            self.calls.append([*base, *args])
            if '--format' in args:
                path = base[base.index('-f') + 1]
                return Path(path).read_text()
            return ''
        fake_command = patch.object(manage, 'command', side_effect=command)
        fake_command.start(); self.addCleanup(fake_command.stop)
        fake_inspect = patch.object(pages, 'inspect', return_value={'State': {'Running': True}})
        fake_inspect.start(); self.addCleanup(fake_inspect.stop)
        ready = patch.object(pages, 'ready')
        ready.start(); self.addCleanup(ready.stop)

    def test_panel_domain_changes_addresses_without_changing_secrets_or_images(self):
        plan = manage.prepare(self.root, 'panel', 'new.example.test')
        self.assertIn('old.example.test', (self.directory / '.env').read_text())
        manage.apply(plan)
        self.assertIn('APP_SECRET=UNCHANGED', (self.directory / '.env').read_text())
        self.assertIn('FRONT_END_DOMAIN=https://new.example.test', (self.directory / '.env').read_text())
        self.assertIn('SUB_PUBLIC_DOMAIN=new.example.test/api/sub', (self.directory / '.env').read_text())
        self.assertNotIn('old.example.test', (self.directory / 'Caddyfile').read_text())
        self.assertEqual(runtime.load(self.root / 'registry/panel.json')['panelDomain'], 'new.example.test')
        self.assertEqual(runtime.load(self.directory / 'docker-compose.yml'), self.config)

    def test_failed_validation_restores_all_files_and_original_address(self):
        before = {p: p.read_bytes() for p in (self.directory / '.env', self.directory / 'Caddyfile', self.root / 'registry/panel.json')}
        plan = manage.prepare(self.root, 'panel', 'new.example.test')
        original = manage.command
        def command(base, *args):
            if 'validate' in args:
                raise RuntimeError('proxy failed')
            return original(base, *args)
        with patch.object(manage, 'command', side_effect=command):
            with self.assertRaises(RuntimeError):
                manage.apply(plan)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)
        self.assertEqual(runtime.load(plan)['phase'], 'rolled-back')

    def test_failed_https_rolls_back_and_does_not_report_completion(self):
        plan = manage.prepare(self.root, 'panel', 'new.example.test')
        manage.apply(plan)
        with patch.object(manage, 'verify_https', side_effect=ValueError('TLS not ready')):
            with self.assertRaises(ValueError):
                manage.complete(plan)
        self.assertEqual(runtime.load(plan)['phase'], 'rolled-back')
        self.assertEqual(runtime.load(self.root / 'registry/panel.json')['panelDomain'], 'old.example.test')

    def test_complete_preserves_stopped_state_without_public_requests(self):
        with patch.object(pages, 'inspect', return_value={'State': {'Running': False}}):
            plan = manage.prepare(self.root, 'panel', 'new.example.test')
        manage.apply(plan)
        with patch.object(manage.urllib.request, 'build_opener', side_effect=AssertionError('network not expected')):
            manage.complete(plan)
        self.assertEqual(runtime.load(plan)['phase'], 'complete')

    def test_stopped_apps_remain_stopped_and_databases_are_not_recreated(self):
        with patch.object(pages, 'inspect', return_value={'State': {'Running': False}}):
            plan = manage.prepare(self.root, 'panel', 'new.example.test')
        manage.apply(plan)
        up = [args for args in self.calls if 'up' in args]
        self.assertTrue(up)
        self.assertTrue(all('--no-start' in args for args in up))
        self.assertTrue(all('--no-deps' in args for args in up))
        self.assertFalse(any('remnawave-db' in args for args in up))

    def test_inline_environment_and_custom_files_are_preserved(self):
        config = copy.deepcopy(self.config)
        config['services']['remnawave']['environment'] = {'FRONT_END_DOMAIN': 'https://old.example.test', 'APP_SECRET': '${APP_SECRET}'}
        runtime.write(self.directory / 'docker-compose.yml', config)
        plan = manage.prepare(self.root, 'panel', 'new.example.test')
        manage.apply(plan)
        updated = runtime.load(self.directory / 'docker-compose.yml')
        self.assertEqual(updated['services']['remnawave']['environment']['FRONT_END_DOMAIN'], 'https://new.example.test')
        self.assertEqual(updated['services']['remnawave']['environment']['APP_SECRET'], '${APP_SECRET}')
        self.assertEqual(updated.get('x-remnacust-release'), config.get('x-remnacust-release'))
        manage.rollback(plan)
        self.assertEqual(runtime.load(self.directory / 'docker-compose.yml'), config)

    def test_changes_after_preparation_are_not_overwritten(self):
        plan = manage.prepare(self.root, 'panel', 'new.example.test')
        runtime.write(self.directory / '.env', 'OPERATOR_CHANGED=yes\n')
        with self.assertRaises(ValueError):
            manage.apply(plan)
        self.assertEqual((self.directory / '.env').read_text(), 'OPERATOR_CHANGED=yes\n')

    def test_invalid_domains_and_symlinks_fail_before_changes(self):
        for domain in ('https://bad.test', 'bad.test;reboot', '../etc', 'bad.test\nother.test'):
            with self.assertRaises(ValueError):
                manage.prepare(self.root, 'panel', domain)
        original = (self.directory / 'Caddyfile').read_text()
        (self.directory / 'Caddyfile').unlink()
        (self.directory / 'Caddyfile').symlink_to(self.directory / '.env')
        with self.assertRaises(ValueError):
            manage.prepare(self.root, 'panel', 'new.example.test')
        self.assertIn('APP_SECRET=UNCHANGED', (self.directory / '.env').read_text())

    def test_proxy_domain_replacement_preserves_contact_credentials_and_upstream(self):
        text = '{\n email admin@old.example.test\n}\nold.example.test {\n reverse_proxy https://old.example.test\n header X-Fixture old.example.test\n}\n'
        actual = manage.proxy_text(text, 'old.example.test', 'new.example.test')
        self.assertIn('\nnew.example.test {', actual)
        self.assertIn('email admin@old.example.test', actual)
        self.assertIn('reverse_proxy https://old.example.test', actual)
        self.assertIn('header X-Fixture old.example.test', actual)
        nginx = 'server {\n server_name old.example.test alias.example.test;\n proxy_set_header Host old.example.test;\n}\n'
        actual = manage.proxy_text(nginx, 'old.example.test', 'new.example.test', 'nginx')
        self.assertIn('server_name new.example.test alias.example.test;', actual)
        self.assertIn('proxy_set_header Host old.example.test;', actual)

    def test_page_domain_and_shared_panel_domain_are_distinct(self):
        self.state.update(subscriptionPage=True, subscriptionUrls=['https://sub.example.test'])
        self.state['applications'].append('remnawave-subscription-page')
        self.config['services']['remnawave-subscription-page'] = {'image': 'page:1.1.7.61'}
        runtime.write(self.directory / 'docker-compose.yml', self.config)
        runtime.write(self.directory / 'Caddyfile', 'old.example.test {\n reverse_proxy remnawave:3000\n}\nsub.example.test {\n reverse_proxy remnawave-subscription-page:3010\n}\n')
        runtime.write(self.root / 'registry/panel.json', self.state)
        page_id = pages.identity({**self.state, 'service': 'remnawave-subscription-page'})
        plan = manage.prepare(self.root, 'subscription-page', 'newsub.example.test', page_id)
        manage.apply(plan)
        result = runtime.load(self.root / 'registry/panel.json')
        self.assertEqual(result['panelDomain'], 'old.example.test')
        self.assertEqual(result['subscriptionUrls'], ['https://newsub.example.test'])
        self.assertIn('FRONT_END_DOMAIN=https://old.example.test', (self.directory / '.env').read_text())

    def test_node_domain_and_certbot_failure_rollback_restore_proxy(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:1.1.11', node_domain='old.example.test')
        state.update(version='1.1.11', tls={'method': 'http'})
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / 'nginx.conf', runtime.nginx_config('old.example.test'))
        runtime.write(directory / '.env', 'SECRET_KEY=UNCHANGED\n')
        runtime.write(self.root / 'registry/node.json', state)
        plan = manage.prepare(self.root, 'node', 'new.example.test')
        manage.stop_proxy(plan)
        manage.rollback(plan)
        self.assertIn('old.example.test', (directory / 'nginx.conf').read_text())
        self.assertTrue(any('up' in row and 'node-nginx' in row for row in self.calls))

    def test_first_node_domain_adds_tls_without_changing_key_or_port_and_can_roll_back(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:1.1.11', number='2222')
        state['version'] = '1.1.11'
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / '.env', 'SECRET_KEY=UNCHANGED\nNODE_PORT=2222\n')
        runtime.write(self.root / 'registry/node.json', state)
        certificate, key = self.root / 'leaf.pem', self.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
                        '-keyout', str(key), '-out', str(certificate), '-days', '3', '-subj', '/CN=new.example.test',
                        '-addext', 'subjectAltName=DNS:new.example.test'], capture_output=True, check=True)
        plan = manage.prepare(self.root, 'node', 'new.example.test')
        manage.stop_proxy(plan)
        self.assertFalse(any('stop' in row for row in self.calls))
        manage.apply(plan, certificate, key)
        updated = runtime.load(self.root / 'registry/node.json')
        self.assertEqual(updated['nodeDomain'], 'new.example.test')
        self.assertIn('node-nginx', updated['extraServices'])
        self.assertIn('node-nginx', updated['ownedServices'])
        self.assertEqual((directory / '.env').read_text(), 'SECRET_KEY=UNCHANGED\nNODE_PORT=2222\n')
        self.assertEqual(updated['apiPort'], 2222)
        self.assertEqual((directory / 'certs/fullchain.pem').read_bytes(), certificate.read_bytes())
        self.assertTrue((directory / 'www/index.html').is_file())
        manage.rollback(plan)
        self.assertEqual(runtime.load(directory / 'docker-compose.yml'), config)
        self.assertFalse((directory / 'nginx.conf').exists())
        self.assertFalse((directory / 'certs/fullchain.pem').exists())

    def test_first_node_domain_does_not_inspect_a_service_missing_from_original_compose(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', number='7289')
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / '.env', 'SECRET_KEY=fixture\nNODE_PORT=7289\n')
        runtime.write(self.root / 'registry/node.json', state)
        def inspect(item):
            self.assertIn(item['service'], config['services'])
            return {'State': {'Running': True}}
        with patch.object(pages, 'inspect', side_effect=inspect):
            plan = runtime.load(manage.prepare(self.root, 'node', 'new.example.test', tls_method='http'))
        self.assertTrue(plan['units'][0]['addedProxy'])
        self.assertTrue(plan['units'][0]['running']['node-nginx'])

    @unittest.skipUnless(os.environ.get('REMNACUST_TEST_REAL_COMPOSE') == '1', 'real Compose validation is opt-in')
    def test_real_compose_validates_first_tls_configuration_without_inspecting_missing_proxy(self):
        from subscription_migration import command
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'tlsregression', 'node:fixture', number='7289')
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / '.env', 'SECRET_KEY=fixture\nNODE_PORT=7289\n')
        runtime.write(self.root / 'registry/node.json', state)
        observed = []
        def inspect(item):
            services = command(manage.compose_base(item), 'config', '--services').splitlines()
            self.assertIn(item['service'], services)
            observed.append(item['service'])
            return {'State': {'Running': True}}
        with patch.object(manage, 'command', command), patch.object(pages, 'inspect', side_effect=inspect):
            plan = runtime.load(manage.prepare(self.root, 'node', 'new.example.test', tls_method='http'))
        self.assertEqual(observed, ['remnanode'])
        self.assertIn('node-nginx', plan['units'][0]['after']['services'])

    def test_first_node_tls_uses_preserved_runtime_mount_and_selected_certificate_method(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture')
        preserved = directory / '.remnacust-node-state-fixture/runtime'
        config['services']['remnanode']['volumes'][0] = {'type': 'bind', 'source': str(preserved), 'target': '/var/lib/remnacust/run'}
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(self.root / 'registry/node.json', state)
        plan = runtime.load(manage.prepare(self.root, 'node', 'edge.example.test', tls_method='existing'))
        self.assertEqual(plan['method'], 'existing')
        mounts = plan['units'][0]['after']['services']['node-nginx']['volumes']
        self.assertEqual(mounts[2]['source'], str(preserved))
        self.assertEqual(plan['units'][0]['after']['services']['remnanode']['image'], 'node:fixture')

    def test_node_tls_can_be_reconfigured_for_same_domain_with_explicit_method(self):
        directory = self.root / 'node'; directory.mkdir()
        config, state = runtime.fresh('node', directory, 'nodefixture', 'node:fixture', node_domain='edge.example.test')
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / 'nginx.conf', runtime.nginx_config('edge.example.test'))
        runtime.write(self.root / 'registry/node.json', state)
        plan = runtime.load(manage.prepare(self.root, 'node', 'edge.example.test', tls_method='gcore'))
        self.assertEqual(plan['method'], 'gcore')
        self.assertNotIn('addedProxy', plan['units'][0])

    def test_invalid_tls_method_does_not_modify_panel_or_node_registry(self):
        before = (self.root / 'registry/panel.json').read_bytes()
        with self.assertRaises(ValueError):
            manage.prepare(self.root, 'panel', 'new.example.test', tls_method='existing')
        self.assertEqual((self.root / 'registry/panel.json').read_bytes(), before)

    def test_separate_page_changes_only_its_domain(self):
        directory = self.root / 'page'; directory.mkdir()
        item = {'directory': str(directory), 'project': 'pagefixture', 'service': 'page',
                'composeFiles': [str(directory / 'docker-compose.yml')], 'domain': 'sub.example.test'}
        config = {'services': {'page': {'image': 'page:test', 'env_file': [str(directory / '.env')]}, 'caddy': {'image': 'caddy:2-alpine'}}}
        runtime.write(directory / 'docker-compose.yml', config)
        runtime.write(directory / '.env', 'TOKEN=UNCHANGED\n')
        runtime.write(directory / 'Caddyfile', 'sub.example.test {\n reverse_proxy page:3010\n}\n')
        page_id = pages.identity(item)
        record = self.root / 'registry/subscription-pages' / (page_id + '.json')
        runtime.write(record, item)
        plan = manage.prepare(self.root, 'subscription-page', 'newsub.example.test', page_id)
        manage.apply(plan)
        self.assertEqual(runtime.load(record)['domain'], 'newsub.example.test')
        self.assertEqual(runtime.load(self.root / 'registry/panel.json'), self.state)
        self.assertEqual((directory / '.env').read_text(), 'TOKEN=UNCHANGED\n')

    def test_linked_local_page_follows_panel_public_url_preserving_credentials(self):
        directory = self.root / 'page'; directory.mkdir()
        item = {'directory': str(directory), 'project': 'pagefixture', 'service': 'page',
                'composeFiles': [str(directory / 'docker-compose.yml')], 'domain': 'sub.example.test'}
        runtime.write(directory / 'docker-compose.yml', {'services': {'page': {'image': 'page:test', 'env_file': [str(directory / '.env')]}}})
        runtime.write(directory / '.env', 'TOKEN=UNCHANGED\nREMNAWAVE_PANEL_URL=https://old.example.test\n')
        runtime.write(self.root / 'registry/subscription-pages' / (pages.identity(item) + '.json'), item)
        def inspect(item):
            return {'State': {'Running': True}, 'Config': {'Env': ['REMNAWAVE_PANEL_URL=https://old.example.test'] if item['service'] == 'page' else []}}
        with patch.object(pages, 'inspect', side_effect=inspect):
            plan = manage.prepare(self.root, 'panel', 'new.example.test')
        manage.apply(plan)
        self.assertIn('REMNAWAVE_PANEL_URL=https://new.example.test', (directory / '.env').read_text())
        self.assertIn('TOKEN=UNCHANGED', (directory / '.env').read_text())
        self.assertTrue(any('up' in row and 'page' in row for row in self.calls))

    def test_migrated_separate_page_updates_parent_subscription_url(self):
        directory = self.root / 'page'; directory.mkdir()
        item = {'directory': str(directory), 'project': 'pagefixture', 'service': 'page',
                'composeFiles': [str(directory / 'docker-compose.yml')]}
        runtime.write(directory / 'docker-compose.yml', {'services': {'page': {'image': 'page:test'}, 'caddy': {'image': 'caddy:2-alpine'}}})
        runtime.write(directory / 'Caddyfile', 'sub.example.test {\n reverse_proxy page:3010\n}\n')
        self.state.update(subscriptionMigration=item, subscriptionUrls=['https://sub.example.test'])
        runtime.write(self.root / 'registry/panel.json', self.state)
        plan = manage.prepare(self.root, 'subscription-page', 'newsub.example.test', pages.identity(item))
        manage.apply(plan)
        parent = runtime.load(self.root / 'registry/panel.json')
        self.assertEqual(parent['panelDomain'], 'old.example.test')
        self.assertEqual(parent['subscriptionUrls'], ['https://newsub.example.test'])
        self.assertIn('SUB_PUBLIC_DOMAIN=newsub.example.test', (self.directory / '.env').read_text())

    def test_migrated_shared_page_preserves_panel_identity(self):
        item = {'directory': str(self.directory), 'project': self.state['project'], 'service': 'page', 'composeFiles': self.state['composeFiles']}
        self.state.update(subscriptionMigration=item, subscriptionUrls=['https://sub.example.test'])
        self.config['services']['page'] = {'image': 'page:test'}
        runtime.write(self.directory / 'docker-compose.yml', self.config)
        runtime.write(self.directory / 'Caddyfile', 'old.example.test {\n reverse_proxy remnawave:3000\n}\nsub.example.test {\n reverse_proxy page:3010\n}\n')
        runtime.write(self.root / 'registry/panel.json', self.state)
        plan = manage.prepare(self.root, 'subscription-page', 'newsub.example.test', pages.identity(item))
        manage.apply(plan)
        parent = runtime.load(self.root / 'registry/panel.json')
        self.assertEqual(parent['component'], 'panel')
        self.assertEqual(parent['panelDomain'], 'old.example.test')
        self.assertFalse(parent.get('subscriptionPage'))
        self.assertEqual(parent['subscriptionMigration']['domain'], 'newsub.example.test')
        self.assertEqual(len(pages.records(self.root)), 1)


if __name__ == '__main__':
    unittest.main()
