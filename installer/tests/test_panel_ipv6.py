import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class PanelIpv6Tests(unittest.TestCase):
    def setUp(self):
        self.config = {
            'name': 'panel',
            'services': {
                'api': {'image': 'panel:old', 'networks': {'legacy': {'aliases': ['api']}},
                        'ports': ['127.0.0.1:3000:3000'], 'environment': {'APP_SECRET': 'fixture'}},
                'worker': {'image': 'panel:old', 'networks': ['legacy']},
                'db': {'image': 'postgres:18.6', 'networks': ['legacy'], 'volumes': ['database:/data']},
                'redis': {'image': 'valkey/valkey:9-alpine', 'networks': ['legacy']},
                'proxy': {'image': 'caddy:2-alpine', 'ports': ['443:443'], 'networks': ['legacy']},
                'page': {'image': 'page:old', 'labels': {'io.remnacust.service-role': 'subscription-page'}},
            },
            'networks': {'legacy': {'name': 'remnawave-network', 'external': True}},
        }
        self.state = {'component': 'panel', 'project': 'panel', 'mainService': 'api', 'applications': ['api', 'worker', 'page']}
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for interface in ['all', 'default', 'eth0']:
            directory = self.root / interface
            directory.mkdir()
            (directory / 'disable_ipv6').write_text('0')
        (self.root / 'eth0/accept_ra').write_text('2')
        (self.root / 'all/forwarding').write_text('0')
        self.outputs = {
            ('ip', '-j', '-6', 'route', 'show', 'default'): json.dumps([{'dev': 'eth0', 'protocol': 'ra'}]),
            ('docker', 'version', '--format', '{{.Server.Version}}'): '28.5.2',
            ('docker', 'compose', 'version', '--short'): 'v2.33.1',
            ('docker', 'network', 'ls', '--format', '{{.Name}}'): '',
        }
        self.commands = []

    def command(self, arguments, **options):
        self.commands.append(tuple(arguments))
        return SimpleNamespace(returncode=0, stdout=self.outputs[tuple(arguments)])

    def preflight(self):
        with patch.object(runtime.subprocess, 'run', self.command):
            runtime.panel_ipv6_preflight('panel', self.root, self.root / 'daemon.json')

    def test_adds_only_panel_endpoints_and_preserves_ipv4_infrastructure_and_ports(self):
        before = copy.deepcopy(self.config)
        result = runtime.panel_ipv6_config(self.config, self.state['applications'], True, 'panel')
        network = result['networks'][runtime.PANEL_IPV6_NETWORK]
        self.assertIs(network['enable_ipv4'], False)
        self.assertIs(network['enable_ipv6'], True)
        self.assertEqual(network['driver_opts']['com.docker.network.bridge.gateway_mode_ipv6'], 'nat')
        self.assertNotIn('ipam', network)
        self.assertEqual(result['networks']['legacy'], before['networks']['legacy'])
        for name in ['db', 'redis', 'proxy', 'page']:
            self.assertEqual(result['services'][name], before['services'][name])
        for name in ['api', 'worker']:
            service = result['services'][name]
            self.assertGreater(service['networks']['legacy']['priority'], service['networks'][runtime.PANEL_IPV6_NETWORK]['priority'])
            self.assertGreater(service['networks']['legacy']['gw_priority'], service['networks'][runtime.PANEL_IPV6_NETWORK]['gw_priority'])
            for key in ['ports', 'environment', 'volumes', 'cap_add', 'sysctls']:
                self.assertEqual(service.get(key), before['services'][name].get(key))
        self.assertEqual(result['services']['api']['networks']['legacy']['aliases'], ['api'])
        self.assertNotIn('ports', result['services']['db'])
        self.assertEqual(self.config, before)

    def test_repeat_normalized_compose_upgrade_and_disable_are_safe(self):
        enabled = runtime.panel_ipv6_config(self.config, ['api', 'worker'], True, 'panel')
        enabled['networks'][runtime.PANEL_IPV6_NETWORK]['name'] = 'panel_' + runtime.PANEL_IPV6_NETWORK
        live = {'Config': {'Labels': {'com.docker.compose.service': 'api'}}}
        upgraded, apps = runtime.transform(enabled, live, 'panel', 'panel:new')
        self.assertEqual(upgraded['networks'], enabled['networks'])
        self.assertEqual(runtime.panel_ipv6_config(upgraded, apps, True, 'panel'), upgraded)
        disabled = runtime.panel_ipv6_config(upgraded, apps, False, 'panel')
        self.assertNotIn(runtime.PANEL_IPV6_NETWORK, disabled['networks'])
        self.assertEqual(disabled['networks']['legacy'], self.config['networks']['legacy'])
        self.assertEqual(disabled['services']['db'], self.config['services']['db'])
        self.assertEqual(runtime.panel_ipv6_config(disabled, apps, False, 'panel'), disabled)

    def test_fresh_default_network_is_retained_for_database_and_cache(self):
        config, state = runtime.fresh('panel', self.root, 'panel', 'panel:new', hostname='panel.example.test', proxy='existing')
        result = runtime.panel_ipv6_config(config, state['applications'], True, 'panel')
        self.assertIn('default', result['services']['remnawave']['networks'])
        self.assertEqual(result['services']['remnawave-db'], config['services']['remnawave-db'])
        self.assertNotIn('networks', result['services']['remnawave-db'])
        self.assertNotIn('ports', result['services']['remnawave-db'])
        self.assertNotIn('ports', result['services']['remnawave-redis'])
        self.assertNotIn('sysctls', result['services']['remnawave'])

    def test_auto_fallback_preserves_existing_config_and_on_fails_before_writes(self):
        for config in [self.config, runtime.panel_ipv6_config(self.config, ['api'], True, 'panel')]:
            before = copy.deepcopy(config)
            with patch.object(runtime, 'panel_ipv6_preflight', side_effect=runtime.ConfigurationError('route missing')), patch('sys.stderr', io.StringIO()):
                self.assertEqual(runtime.configure_panel_ipv6(config, self.state, 'auto'), before)
                with self.assertRaisesRegex(runtime.ConfigurationError, 'route missing'):
                    runtime.configure_panel_ipv6(config, self.state, 'on')
            self.assertEqual(config, before)
        with patch.object(runtime, 'panel_ipv6_preflight') as probe:
            self.assertEqual(runtime.configure_panel_ipv6(self.config, self.state, 'off'), self.config)
            probe.assert_not_called()

    def test_auto_enables_on_safe_host_and_node_is_rejected(self):
        with patch.object(runtime, 'panel_ipv6_preflight'):
            result = runtime.configure_panel_ipv6(self.config, self.state, 'auto')
            self.assertIn(runtime.PANEL_IPV6_NETWORK, result['networks'])
            self.assertIn(runtime.PANEL_IPV6_NETWORK, result['services']['api']['networks'])
            self.assertIn(runtime.PANEL_IPV6_NETWORK, result['services']['worker']['networks'])
            self.assertEqual(result['services']['page'], self.config['services']['page'])
        with self.assertRaises(runtime.ConfigurationError):
            runtime.configure_panel_ipv6(self.config, {**self.state, 'component': 'node'}, 'auto')
        node, _ = runtime.fresh('node', self.root, 'node', 'node:new')
        self.assertEqual(node['services']['remnanode']['network_mode'], 'host')
        self.assertNotIn('sysctls', node['services']['remnanode'])

    def test_real_configure_attaches_and_detaches_every_discovered_panel_backend(self):
        config = copy.deepcopy(self.config)
        config['services']['worker']['environment'] = {'INSTANCE_TYPE': 'processor'}
        config['services']['scheduler'] = {
            'image': 'scheduler:old', 'environment': {'INSTANCE_TYPE': 'scheduler'}, 'networks': ['legacy']}
        config['services']['node'] = {'image': 'node:old', 'network_mode': 'host'}
        live = {'Config': {'Labels': {'com.docker.compose.service': 'api'}}}
        candidate, applications = runtime.transform(config, live, 'panel', 'panel:new', subscription_image='page:new')
        self.assertTrue({'api', 'worker', 'scheduler', 'page'}.issubset(applications))
        state = {**self.state, 'applications': [name for name in applications if name != 'api'] + ['worker']}
        before = copy.deepcopy(candidate)
        with patch.object(runtime, 'panel_ipv6_preflight') as preflight:
            enabled = runtime.configure_panel_ipv6(candidate, state, 'on')
            self.assertEqual(preflight.call_count, 1)
            for name in ['api', 'worker', 'scheduler']:
                self.assertIn(runtime.PANEL_IPV6_NETWORK, enabled['services'][name]['networks'])
            for name in ['page', 'db', 'redis', 'proxy', 'node']:
                self.assertEqual(enabled['services'][name], before['services'][name])
            self.assertEqual(runtime.configure_panel_ipv6(enabled, state, 'auto'), enabled)
            preflight.reset_mock()
            disabled = runtime.configure_panel_ipv6(enabled, state, 'off')
            preflight.assert_not_called()
        for name in ['api', 'worker', 'scheduler']:
            self.assertNotIn(runtime.PANEL_IPV6_NETWORK, disabled['services'][name]['networks'])
        for name in ['page', 'db', 'redis', 'proxy', 'node']:
            self.assertEqual(disabled['services'][name], before['services'][name])
        self.assertNotIn(runtime.PANEL_IPV6_NETWORK, disabled['networks'])
        self.assertEqual(candidate, before)

    def test_conflicting_name_host_network_and_disabling_sysctls_fail_closed(self):
        for change in [{'network_mode': 'host'}, {'sysctls': {'net.ipv6.conf.all.disable_ipv6': 1}},
                       {'sysctls': ['net.ipv6.conf.default.disable_ipv6=1']}]:
            config = copy.deepcopy(self.config)
            config['services']['api'].update(change)
            with self.assertRaises(runtime.ConfigurationError):
                runtime.panel_ipv6_config(config, ['api'], True, 'panel')
        config = copy.deepcopy(self.config)
        config['networks'][runtime.PANEL_IPV6_NETWORK] = {'external': True, 'name': 'foreign'}
        with self.assertRaises(runtime.ConfigurationError):
            runtime.panel_ipv6_config(config, ['api'], True, 'panel')

    def test_preflight_only_reads_and_requires_safe_ra_acceptance(self):
        self.preflight()
        self.assertEqual(self.commands, list(self.outputs))
        self.assertEqual((self.root / 'all/forwarding').read_text(), '0')
        (self.root / 'eth0/accept_ra').write_text('1')
        with self.assertRaisesRegex(runtime.ConfigurationError, 'accept_ra=2'):
            self.preflight()
        self.assertEqual((self.root / 'eth0/accept_ra').read_text(), '1')

    def test_existing_forwarding_preserves_managed_ra_without_changing_acceptance(self):
        (self.root / 'all/forwarding').write_text('1')
        for acceptance in ['0', '1', '2']:
            (self.root / 'eth0/accept_ra').write_text(acceptance)
            self.preflight()
            self.assertEqual((self.root / 'all/forwarding').read_text(), '1')
            self.assertEqual((self.root / 'eth0/accept_ra').read_text(), acceptance)

    def test_missing_routes_disabled_ipv6_and_old_docker_compose_are_rejected(self):
        for key, value in [(('ip', '-j', '-6', 'route', 'show', 'default'), '[]'),
                           (('docker', 'version', '--format', '{{.Server.Version}}'), '27.5.1'),
                           (('docker', 'compose', 'version', '--short'), '2.33.0')]:
            original = self.outputs[key]
            self.outputs[key] = value
            with self.assertRaises(runtime.ConfigurationError):
                self.preflight()
            self.outputs[key] = original
        (self.root / 'default/disable_ipv6').write_text('1')
        with self.assertRaises(runtime.ConfigurationError):
            self.preflight()

    def test_static_route_needs_no_ra_override_and_disabled_nat_is_rejected(self):
        self.outputs[('ip', '-j', '-6', 'route', 'show', 'default')] = json.dumps([{'dev': 'eth0', 'protocol': 'static'}])
        (self.root / 'eth0/accept_ra').write_text('0')
        self.preflight()
        (self.root / 'daemon.json').write_text(json.dumps({'ip6tables': False}))
        with self.assertRaisesRegex(runtime.ConfigurationError, 'ip6tables'):
            self.preflight()

    def test_existing_network_requires_ownership_ipv6_only_and_nat(self):
        name = 'panel_' + runtime.PANEL_IPV6_NETWORK
        self.outputs[('docker', 'network', 'ls', '--format', '{{.Name}}')] = name
        network = {'Driver': 'bridge', 'EnableIPv4': False, 'EnableIPv6': True, 'Internal': False,
                   'Labels': {'com.docker.compose.project': 'panel', 'com.docker.compose.network': runtime.PANEL_IPV6_NETWORK}}
        for extra in [{}, {'EnableIPv4': True}, {'Internal': True}, {'Labels': {}},
                      {'Options': {'com.docker.network.bridge.gateway_mode_ipv6': 'routed'}}]:
            self.outputs[('docker', 'network', 'inspect', name)] = json.dumps([{**network, **extra}])
            if extra:
                with self.assertRaises(runtime.ConfigurationError): self.preflight()
            else:
                self.preflight()

    @unittest.skipUnless(os.name == 'posix' and hasattr(os, 'fchmod'), 'Actual installer CLI requires POSIX descriptor permissions')
    def test_helper_off_only_writes_fixture_files(self):
        config = runtime.panel_ipv6_config(self.config, ['api', 'worker'], True, 'panel')
        source, state = self.root / 'compose.json', self.root / 'state.json'
        source.write_text(json.dumps(config))
        state.write_text(json.dumps(self.state))
        result = subprocess.run([sys.executable, '-B', str(Path(runtime.__file__)), 'panel-ipv6',
                                 '--source', str(source), '--state', str(state), '--key', 'off'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(state.read_text())['panelIpv6'])
        self.assertEqual(json.loads(source.read_text())['services']['db'], self.config['services']['db'])

    def test_permission_failure_keeps_original_file_and_closes_temporary_descriptor(self):
        target = self.root / 'original.json'
        target.write_text('original fixture')
        created = []
        mkstemp = runtime.tempfile.mkstemp
        def capture(**options):
            item = mkstemp(**options)
            created.append(item)
            return item
        with patch.object(runtime.tempfile, 'mkstemp', capture), patch.object(
                runtime.os, 'fchmod', create=True, side_effect=PermissionError('fixture chmod denied')):
            with self.assertRaisesRegex(PermissionError, 'fixture chmod denied'):
                runtime.write(target, {'updated': True})
        self.assertEqual(target.read_text(), 'original fixture')
        self.assertEqual(len(created), 1)
        with self.assertRaises(OSError):
            os.fstat(created[0][0])
        self.assertFalse(Path(created[0][1]).exists())


@unittest.skipIf(os.name == 'nt' and not os.environ.get('REMNACUST_TEST_BASH'), 'Requires POSIX Bash')
class PanelIpv6CliTests(unittest.TestCase):
    def shell(self, body):
        entry = Path(__file__).resolve().parents[1] / 'installer.sh'
        return subprocess.run([os.environ.get('REMNACUST_TEST_BASH', 'bash'), '-c', 'source "$1"; ' + body, 'test', entry.as_posix()],
                              capture_output=True, text=True, encoding='utf-8', timeout=15)

    def test_default_auto_and_explicit_modes_are_scoped_to_panel_actions(self):
        result = self.shell('parse_args upgrade-panel; printf "%s" "$PANEL_IPV6_MODE"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'auto')
        for mode in ['auto', 'on', 'off']:
            self.assertEqual(self.shell('parse_args upgrade-panel --panel-ipv6 ' + mode).returncode, 0)
        for action in ['install-node', 'upgrade-node', 'status', 'restore-panel']:
            self.assertNotEqual(self.shell('parse_args ' + action + ' --panel-ipv6 on').returncode, 0)
        self.assertNotEqual(self.shell('parse_args upgrade-panel --panel-ipv6 invalid').returncode, 0)
        result = self.shell('parse_args --panel-ipv6 on; COMPONENT=node; ACTION=install-node; deploy')
        self.assertNotEqual(result.returncode, 0)

    def test_candidate_is_only_processed_for_panel_install_upgrade_and_migration(self):
        for action in ['install-panel', 'upgrade-panel', 'migrate-remnawave-panel']:
            result = self.shell('ACTION=' + action + '; COMPONENT=panel; STATE=fixture; helper() { printf "%s " "$@"; }; panel_ipv6_candidate compose.json')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('panel-ipv6 --source compose.json --state fixture --key auto', result.stdout)
        for action in ['status', 'show-config', 'restore-panel']:
            result = self.shell('ACTION=' + action + '; COMPONENT=panel; helper() { return 99; }; panel_ipv6_candidate unused')
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
