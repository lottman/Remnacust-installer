import copy
import hashlib
import hmac
import importlib.util
import json
import http.client
import os
from pathlib import Path
import subprocess
import sys
import socket
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'installer'))
import runtime
spec = importlib.util.spec_from_file_location('update_agent', Path(__file__).resolve().parents[1] / 'installer/update-agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'control').mkdir(mode=0o700)
        self.current = {'component': 'panel', 'version': '1.1.7.4'}
        runtime.write(self.root / 'registry/panel.json', self.current)
        self.agent = agent.Agent(self.root)
        self.agent.save({'active': False, 'phase': 'idle', 'jobId': None, 'targetVersion': None, 'error': None})
        self.request = str(uuid.uuid4())

    def tearDown(self):
        self.temp.cleanup()

    def start(self):
        with patch.object(agent.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            return self.agent.start('1.1.7.5', self.request)

    def test_start_detaches_worker_and_is_idempotent(self):
        with patch.object(agent.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertTrue(self.agent.start('1.1.7.5', self.request)['active'])
            self.assertEqual(self.agent.start('1.1.7.5', self.request)['jobId'], self.request)
            self.assertEqual(run.call_count, 1)
            command = run.call_args.args[0]
            self.assertEqual(command[0], 'systemd-run')
            self.assertEqual(command[-2:], ['--job', self.request])
            self.assertIn('--property=RuntimeMaxSec=7200', command)
            self.assertNotIn('1.1.7.5', command)
        with self.assertRaisesRegex(agent.UpdateError, 'UPDATE_BUSY'):
            self.agent.start('1.1.7.6', str(uuid.uuid4()))

    def test_no_downgrade_invalid_input_or_uninstalled_panel(self):
        for value in ['1.1.7.4', '1.1.7.3', '1.1.7', '1.1.7.4;id', '../foo', '1.1.7.5-beta', '9' * 200 + '.1.1']:
            with self.assertRaises(agent.UpdateError):
                self.agent.start(value, self.request)
        with self.assertRaises(ValueError):
            self.agent.start('1.1.7.5', '../job')
        runtime.write(self.root / 'registry/panel.json', {**self.current, 'uninstalled': True})
        self.assertFalse(self.agent.status()['available'])
        with self.assertRaisesRegex(agent.UpdateError, 'NOT_INSTALLED'):
            self.agent.start('1.1.7.5', self.request)

    def test_launch_failure_releases_maintenance(self):
        with patch.object(agent.subprocess, 'run', side_effect=OSError('private details')):
            with self.assertRaisesRegex(agent.UpdateError, 'START_FAILED'):
                self.agent.start('1.1.7.5', self.request)
        self.assertFalse(self.agent.state()['active'])
        self.assertEqual(self.agent.state()['error'], 'START_FAILED')

    def test_log_creation_failure_is_terminal(self):
        self.start()
        (self.root / 'logs').mkdir(mode=0o700)
        (self.root / 'logs' / ('panel-update-' + self.request + '.log')).write_text('fixture')
        with patch.object(agent.subprocess, 'run') as run:
            self.agent.work(self.request)
        run.assert_not_called()
        self.assertFalse(self.agent.state()['active'])
        self.assertEqual(self.agent.state()['error'], 'UPDATE_FAILED')

    def test_dead_worker_releases_lock_but_running_worker_is_preserved(self):
        self.start()
        state = self.agent.state(); state['startedAt'] = time.time() - 61; self.agent.save(state)
        with patch.object(agent.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.agent.lock():
                self.assertTrue(self.agent.status()['active'])
            self.assertEqual(self.agent.status()['error'], 'INTERRUPTED')
            self.assertFalse(self.agent.state()['active'])

    def work(self, panel_version='1.1.7.5', fail=False):
        self.start()
        calls = []
        def run(command, **options):
            calls.append(command)
            if '--check-release' in command:
                runtime.write(options['env']['REMNACUST_RELEASE_INFO_FILE'], {'installerVersion': '1.2.25', 'panelVersion': panel_version})
                runtime.write(options['env']['REMNACUST_RELEASE_ENTRY_FILE'], '#!/usr/bin/env bash\nexit 0\n')
            elif 'upgrade-panel' in command:
                if fail: raise subprocess.CalledProcessError(1, command)
                runtime.write(self.root / 'registry/panel.json', {**self.current, 'version': panel_version})
            return subprocess.CompletedProcess(command, 0)
        with patch.object(agent.subprocess, 'run', side_effect=run):
            self.agent.work(self.request)
        return calls

    def test_verified_release_update_records_completion(self):
        commands = self.work()
        self.assertEqual(commands[1], ['/usr/bin/bash', str(self.root / 'control' / ('release-' + self.request + '.sh')), 'upgrade-panel', '--version', '1.2.25', '--yes'])
        self.assertEqual(self.agent.state()['phase'], 'completed')
        self.assertFalse(self.agent.state()['active'])
        self.assertEqual((self.root / 'logs' / ('panel-update-' + self.request + '.log')).stat().st_mode & 0o777, 0o600)
        self.assertFalse(list((self.root / 'control').glob('release-*.json')))
        self.assertFalse(list((self.root / 'control').glob('release-*.sh')))

    def test_mismatched_release_never_runs_upgrade(self):
        self.assertEqual(len(self.work('1.1.7.4')), 1)
        self.assertEqual(self.agent.state()['error'], 'RELEASE_NOT_READY')
        self.assertFalse(self.agent.state()['active'])

    def test_installer_failure_is_terminal_without_raw_error_exposure(self):
        self.work(fail=True)
        self.assertEqual(self.agent.state()['phase'], 'failed')
        self.assertEqual(self.agent.state()['error'], 'UPDATE_FAILED')

    def test_setup_preserves_infrastructure_and_shares_control_with_all_applications(self):
        directory = self.root / 'panel'; directory.mkdir()
        secret = 'a' * 64
        (directory / '.env').write_text('APP_SECRET=' + secret + '\n')
        services = {'api': {'image': 'panel:old', 'volumes': ['data:/data']},
                    'second-api': {'image': 'panel:old'},
                    'caddy': {'image': 'caddy', 'ports': ['443:443'], 'volumes': ['certs:/data']},
                    'db': {'image': 'postgres', 'volumes': ['db:/var/lib/postgresql/data']}}
        config = {'services': services, 'volumes': {'data': {}, 'certs': {}, 'db': {}}}
        original = copy.deepcopy(config)
        runtime.write(self.root / 'state.json', {'directory': str(directory), 'mainService': 'api', 'applications': ['api', 'second-api']})
        runtime.write(self.root / 'compose.json', config)
        with patch.object(agent, 'UNIT_ROOT', self.root / 'units'), patch.object(agent.subprocess, 'run'):
            agent.setup(self.root, self.root / 'state.json', self.root / 'compose.json')
        result = runtime.load(self.root / 'compose.json')
        self.assertEqual(result['services']['db'], original['services']['db'])
        self.assertEqual(result['services']['caddy'], original['services']['caddy'])
        self.assertEqual(result['volumes'], original['volumes'])
        self.assertEqual(result['services']['api']['volumes'][0], 'data:/data')
        for name in ['api', 'second-api']:
            self.assertEqual(result['services'][name]['volumes'][-1], {'type': 'bind', 'source': str(self.root / 'control'), 'target': agent.CONTAINER_CONTROL, 'read_only': True})
        token = agent.read_json(self.root / 'update-agent.json')['token']
        self.assertEqual(token, hmac.new(secret.encode(), agent.PURPOSE, hashlib.sha256).hexdigest())
        self.assertNotIn(secret, (self.root / 'update-agent.json').read_text())
        self.assertEqual((self.root / 'update-agent.json').stat().st_mode & 0o777, 0o600)

    def test_only_expected_read_only_control_mount_may_be_added(self):
        before = {'Mounts': [{'Type': 'volume', 'Source': 'db', 'Destination': '/data', 'RW': True}]}
        after = copy.deepcopy(before)
        control = {'Type': 'bind', 'Source': str(self.root / 'control'), 'Destination': agent.CONTAINER_CONTROL, 'RW': False}
        after['Mounts'].append(control)
        with patch.dict(os.environ, {'REMNACUST_ROOT': str(self.root)}):
            runtime.compare_environment(before, after)
            for patch_value in [{'RW': True}, {'Source': '/var/run/docker.sock'}, {'Destination': '/other'}]:
                changed = copy.deepcopy(after); changed['Mounts'][-1].update(patch_value)
                with self.assertRaises(runtime.ConfigurationError): runtime.compare_environment(before, changed)
            after['Mounts'][0]['Source'] = 'different-db'
            with self.assertRaises(runtime.ConfigurationError): runtime.compare_environment(before, after)

    def test_state_and_locks_reject_symbolic_links(self):
        other = self.root / 'other'; other.write_text('{}')
        status = self.root / 'control/status.json'; status.unlink(); status.symlink_to(other)
        with self.assertRaises(OSError): self.agent.state()
        with self.assertRaises(runtime.ConfigurationError): self.agent.save({})
        (self.root / 'control/update.lock').symlink_to(other)
        with self.assertRaises(OSError):
            with self.agent.lock(): pass

    def test_real_unix_socket_requires_authentication_and_limits_input(self):
        token = 'b' * 64
        runtime.write(self.root / 'update-agent.json', {'token': token})
        script = Path(__file__).resolve().parents[1] / 'installer/update-agent.py'
        bootstrap = ('import importlib.util,sys;from pathlib import Path;'
                     'sys.path.insert(0,str(Path(sys.argv[2]).parent));'
                     's=importlib.util.spec_from_file_location("update_agent",sys.argv[2]);'
                     'm=importlib.util.module_from_spec(s);s.loader.exec_module(m);'
                     'm.serve(m.Agent(Path(sys.argv[1])))')
        process = subprocess.Popen([sys.executable, '-c', bootstrap, str(self.root), str(script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            socket_path = self.root / 'control/update.sock'
            for _ in range(100):
                if socket_path.exists(): break
                if process.poll() is not None: self.fail('Socket service exited')
                time.sleep(0.02)
            self.assertTrue(socket_path.is_socket())
            self.assertEqual(socket_path.stat().st_mode & 0o777, 0o600)
            class Connection(http.client.HTTPConnection):
                def connect(connection):
                    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    connection.sock.settimeout(3)
                    connection.sock.connect(str(socket_path))
            def request(method, route, body=None, token_value=token):
                connection = Connection('localhost')
                try:
                    connection.request(method, route, body=body, headers={'Authorization': 'Bearer ' + token_value})
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally: connection.close()
            self.assertEqual(request('GET', '/status', token_value='wrong')[0], 403)
            code, result = request('GET', '/status')
            self.assertEqual(code, 200)
            self.assertTrue(result['available'])
            for body in ['not json', '{}', 'x' * 257, json.dumps({'targetVersion': '1.1.7.5', 'requestId': self.request, 'command': 'reboot'})]:
                self.assertEqual(request('POST', '/update', body)[0], 400)
            self.assertEqual(request('POST', '/update', json.dumps({'targetVersion': '1.1.7.4', 'requestId': self.request}))[0], 400)
            self.assertFalse(self.agent.state()['active'])
            self.assertEqual(request('GET', '/other')[0], 404)
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__': unittest.main()
