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
import io

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
            self.assertIn(['/usr/bin/python3', '-B', agent.SCRIPT], [command[index:index+3] for index in range(len(command)-2)])
        with self.assertRaisesRegex(agent.UpdateError, 'UPDATE_BUSY'):
            self.agent.start('1.1.7.6', str(uuid.uuid4()))

    def test_page_actions_are_bounded_registered_and_idempotent(self):
        page = 'a' * 24
        with patch.object(agent.subscription_pages, 'selected', return_value={}), patch.object(agent.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            first = self.agent.page_start(page, 'restart', self.request)
            self.assertEqual(first['phase'], 'queued')
            self.assertEqual(self.agent.page_start(page, 'restart', self.request), first)
            self.assertEqual(run.call_count, 1)
            self.assertNotIn('restart', run.call_args.args[0])
            with self.assertRaisesRegex(agent.UpdateError, 'UPDATE_BUSY'):
                self.agent.page_start(page, 'upgrade', str(uuid.uuid4()))
            with self.assertRaisesRegex(agent.UpdateError, 'INVALID_REQUEST'):
                self.agent.page_start(page, 'exec', self.request)
            with self.assertRaisesRegex(agent.UpdateError, 'INVALID_REQUEST'):
                self.agent.page_start(page, 'stop', self.request)
        with self.assertRaises(ValueError):
            self.agent.page_start('../panel', 'restart', self.request)

    def test_discovered_page_upgrade_requires_migration_before_spawning_worker(self):
        with patch.object(agent.subscription_pages, 'selected', return_value={'managed': False}), patch.object(agent.subprocess, 'run') as run:
            with self.assertRaisesRegex(agent.UpdateError, 'PAGE_MIGRATION_REQUIRED'):
                self.agent.page_start('a' * 24, 'upgrade', self.request)
            run.assert_not_called()
        self.assertFalse((self.root / 'control' / ('page-' + 'a' * 24 + '.json')).exists())

    def test_failed_page_operation_is_reported_without_private_output(self):
        page = 'a' * 24
        (self.root / 'logs').mkdir()
        with patch.object(agent.subscription_pages, 'selected', return_value={}), patch.object(agent.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            self.agent.page_start(page, 'upgrade', self.request)
        def fail(*args, **kwargs):
            self.assertEqual(args[0], [agent.CLI, 'upgrade-subscription-page', '--version', 'latest', '--page-id', page, '--yes'])
            raise subprocess.CalledProcessError(1, 'private-credential')
        with patch.object(agent.subscription_pages, 'selected', return_value={}), patch.object(agent.subprocess, 'run', side_effect=fail):
            self.agent.page_work(page, self.request)
        job = runtime.load(self.root / 'control' / ('page-' + page + '.json'))
        self.assertEqual(job['phase'], 'failed')
        self.assertEqual(job['error'], 'PAGE_OPERATION_FAILED')
        self.assertNotIn('private-credential', json.dumps(job))

    def test_page_discovery_failure_finishes_job_and_permits_a_new_request(self):
        page = 'a' * 24
        with patch.object(agent.subscription_pages, 'selected', return_value={}), patch.object(agent.subprocess, 'run'):
            self.agent.page_start(page, 'restart', self.request)
        with patch.object(agent.subscription_pages, 'selected', side_effect=ValueError('private Docker details')), patch.object(agent.subprocess, 'run') as run:
            self.agent.page_work(page, self.request)
            run.assert_not_called()
        saved = runtime.load(self.root / 'control' / ('page-' + page + '.json'))
        self.assertEqual((saved['phase'], saved['error']), ('failed', 'PAGE_OPERATION_FAILED'))
        self.assertNotIn('private Docker details', json.dumps(saved))
        with patch.object(agent.subscription_pages, 'selected', return_value={}), patch.object(agent.subprocess, 'run'):
            retry = self.agent.page_start(page, 'restart', str(uuid.uuid4()))
        self.assertEqual(retry['phase'], 'queued')

    def test_page_worker_records_changed_ownership_and_ignores_stale_requests(self):
        page = 'b' * 24
        with patch.object(agent.subscription_pages, 'selected', return_value={}), patch.object(agent.subprocess, 'run'):
            self.agent.page_start(page, 'upgrade', self.request)
        with patch.object(agent.subscription_pages, 'selected', return_value={'managed': False}), patch.object(agent.subprocess, 'run') as run:
            self.agent.page_work(page, self.request)
            run.assert_not_called()
        path = self.root / 'control' / ('page-' + page + '.json')
        self.assertEqual(runtime.load(path)['phase'], 'failed')
        before = path.read_bytes()
        with patch.object(agent.subscription_pages, 'selected') as selected:
            self.agent.page_work(page, str(uuid.uuid4()))
            selected.assert_not_called()
        self.assertEqual(path.read_bytes(), before)

    def test_progress_is_bounded_monotonic_and_estimate_requires_a_successful_baseline(self):
        self.start()
        for index in range(35):
            agent.record_progress(self.root, self.request, 'download', 'Step ' + str(index), 'running')
        agent.record_progress(self.root, self.request, 'checking', 'Earlier optional step', 'done')
        progress = self.agent.status()['progress']
        self.assertEqual(progress['stage'], 'download')
        self.assertEqual(len(progress['events']), 24)
        self.assertIsNone(progress['estimatedRemainingSeconds'])
        runtime.write(self.root / 'control/update-timings.json', {'durations': dict.fromkeys(agent.STAGES, 30)})
        self.assertGreater(self.agent.status()['progress']['estimatedRemainingSeconds'], 0)
        self.assertLess(len(json.dumps(self.agent.status()).encode()), 16384)
        state = self.agent.state(); state.update(active=False, phase='completed', finishedAt=time.time()); self.agent.save(state)
        self.assertEqual(self.agent.status()['progress']['percent'], 100)
        self.assertIsNone(self.agent.status()['progress']['estimatedRemainingSeconds'])

    def test_progress_from_another_job_cannot_replace_current_events(self):
        self.start()
        agent.record_progress(self.root, str(uuid.uuid4()), 'download', 'Wrong job', 'running')
        self.assertIsNone(self.agent.status()['progress'])

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
        self.assertEqual((self.root / 'logs' / ('panel-update-' + self.request + '.log')).read_text(), 'fixture')

    def test_release_resolution_failure_is_retained_only_in_private_log(self):
        self.start()
        detail = 'private network failure fixture'
        with patch.object(agent, 'latest_installer_release', side_effect=OSError(detail)), patch.object(agent.subprocess, 'run') as commands:
            self.agent.work(self.request)
        commands.assert_not_called()
        log = self.root / 'logs' / ('panel-update-' + self.request + '.log')
        self.assertIn(detail, log.read_text())
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(detail, json.dumps(self.agent.status()))
        self.assertEqual(self.agent.state()['phase'], 'failed')

    def test_dead_worker_releases_lock_but_running_worker_is_preserved(self):
        self.start()
        state = self.agent.state(); state['startedAt'] = time.time() - 61; self.agent.save(state)
        with patch.object(agent.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.agent.lock():
                self.assertTrue(self.agent.status()['active'])
            self.assertEqual(self.agent.status()['error'], 'INTERRUPTED')
            self.assertFalse(self.agent.state()['active'])

    def work(self, panel_version='1.1.7.5', fail=False, installer_version='1.2.25', current_version=None):
        self.start()
        calls = []
        def run(command, **options):
            calls.append(command)
            if '--check-release' in command:
                self.assertEqual(command[-2:], ['--version', '1.2.25'])
                if current_version:
                    runtime.write(self.root / 'registry/panel.json', {**self.current, 'version': current_version})
                runtime.write(options['env']['REMNACUST_RELEASE_INFO_FILE'], {'installerVersion': installer_version, 'panelVersion': panel_version})
                runtime.write(options['env']['REMNACUST_RELEASE_ENTRY_FILE'], '#!/usr/bin/env bash\nexit 0\n')
            elif 'upgrade-panel' in command:
                if fail: raise subprocess.CalledProcessError(1, command)
                runtime.write(self.root / 'registry/panel.json', {**self.current, 'version': panel_version})
            return subprocess.CompletedProcess(command, 0)
        with patch.object(agent.subprocess, 'run', side_effect=run), patch.object(agent, 'latest_installer_release', return_value='1.2.25'):
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

    def test_newer_published_panel_supersedes_stale_browser_notification(self):
        self.assertEqual(len(self.work('1.1.7.6')), 2)
        state = self.agent.state()
        self.assertEqual(state['phase'], 'completed')
        self.assertEqual(state['requestedVersion'], '1.1.7.5')
        self.assertEqual(state['targetVersion'], '1.1.7.6')
        self.assertEqual(self.agent.installed(), '1.1.7.6')
        self.assertTrue(any('1.1.7.6' in item['label'] for item in self.agent.status()['progress']['events']))

    def test_resolved_release_cannot_downgrade_a_concurrently_updated_panel(self):
        self.assertEqual(len(self.work('1.1.7.6', current_version='1.1.7.7')), 1)
        self.assertEqual(self.agent.state()['error'], 'NOT_NEWER')

    def test_cli_must_verify_the_same_installer_tag_resolved_before_checking(self):
        self.assertEqual(len(self.work(installer_version='1.2.24')), 1)
        self.assertEqual(self.agent.state()['error'], 'INVALID_RELEASE')

    def test_metadata_failure_does_not_start_installer_or_leave_maintenance_active(self):
        self.start()
        with patch.object(agent, 'latest_installer_release', side_effect=OSError('private network details')), patch.object(agent.subprocess, 'run') as run:
            self.agent.work(self.request)
        run.assert_not_called()
        self.assertFalse(self.agent.state()['active'])
        self.assertEqual(self.agent.state()['error'], 'UPDATE_FAILED')
        self.assertEqual(self.agent.installed(), self.current['version'])

    def test_latest_metadata_is_fresh_bounded_and_stable(self):
        release = {'tag_name': 'v1.2.70', 'draft': False, 'prerelease': False}
        with patch.dict(os.environ, {'REMNACUST_REPOSITORY': 'lottman/Remnacust-installer'}):
            with patch.object(agent, 'urlopen', side_effect=lambda *_args, **_kwargs: io.BytesIO(json.dumps(release).encode())) as opened:
                self.assertEqual(agent.latest_installer_release(), '1.2.70')
                first = opened.call_args.args[0]
                self.assertTrue(first.full_url.startswith('https://api.github.com/repos/lottman/Remnacust-installer/releases/latest?remnacust_check='))
                self.assertEqual(first.get_header('Cache-control'), 'no-cache')
                self.assertEqual(opened.call_args.kwargs['timeout'], 15)
                agent.latest_installer_release()
                self.assertNotEqual(first.full_url, opened.call_args.args[0].full_url)
            for value in [{**release, 'draft': True}, {**release, 'prerelease': True}, {**release, 'tag_name': 'main'}, []]:
                with patch.object(agent, 'urlopen', return_value=io.BytesIO(json.dumps(value).encode())), self.assertRaises(agent.UpdateError):
                    agent.latest_installer_release()
            with patch.object(agent, 'urlopen', return_value=io.BytesIO(b' ' * (256 * 1024 + 1))), self.assertRaises(agent.UpdateError):
                agent.latest_installer_release()

    def test_installer_failure_is_terminal_without_raw_error_exposure(self):
        self.work(fail=True)
        self.assertEqual(self.agent.state()['phase'], 'failed')
        self.assertEqual(self.agent.state()['error'], 'UPDATE_FAILED')
        self.assertEqual(self.agent.status()['progress']['events'][-1]['event'], 'failed')

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
        unit = (self.root / 'units' / agent.SERVICE).read_text()
        self.assertIn('ExecStart=/usr/bin/python3 -B ' + json.dumps(agent.SCRIPT).replace('%', '%%'), unit)
        self.assertEqual(agent.SCRIPT, str((Path(__file__).resolve().parents[1] / 'installer/update-agent.py').resolve()))
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

    def test_restore_refreshes_only_existing_agent_identity_from_actual_container(self):
        inspection = self.root / 'inspection.json'
        secret = 'restored-identity-' + 'b' * 48
        runtime.write(inspection, [{'Config': {'Env': ['APP_SECRET=' + secret]}}])
        with patch.object(agent.subprocess, 'run') as commands:
            agent.restore_identity(self.root, inspection)
            self.assertFalse((self.root / 'update-agent.json').exists())
            runtime.write(self.root / 'update-agent.json', {'token': 'a' * 64})
            before = (self.root / 'control/status.json').read_bytes()
            agent.restore_identity(self.root, inspection)
            expected = hmac.new(secret.encode(), agent.PURPOSE, hashlib.sha256).hexdigest()
            self.assertEqual(agent.read_json(self.root / 'update-agent.json'), {'token': expected})
            self.assertEqual((self.root / 'control/status.json').read_bytes(), before)
            self.assertEqual((self.root / 'update-agent.json').stat().st_mode & 0o777, 0o600)
            commands.assert_not_called()

    def test_restore_identity_refuses_invalid_secret_and_symlink_without_overwriting(self):
        inspection = self.root / 'inspection.json'
        token = self.root / 'update-agent.json'
        runtime.write(token, {'token': 'a' * 64})
        for secret in ['short', 'b' * 32 + '\n']:
            runtime.write(inspection, [{'Config': {'Env': ['APP_SECRET=' + secret]}}])
            with self.assertRaisesRegex(agent.UpdateError, 'MISSING_SECRET'): agent.restore_identity(self.root, inspection)
            self.assertEqual(agent.read_json(token)['token'], 'a' * 64)
        token.unlink()
        other = self.root / 'operator-file.json'; runtime.write(other, {'token': 'operator-value'})
        token.symlink_to(other)
        with self.assertRaisesRegex(agent.UpdateError, 'UNSAFE_PATH'): agent.restore_identity(self.root, inspection)
        self.assertEqual(agent.read_json(other)['token'], 'operator-value')

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
            inspection = self.root / 'restored-container.json'
            secret = 'restored-agent-identity-' + 'c' * 48
            runtime.write(inspection, [{'Config': {'Env': ['APP_SECRET=' + secret]}}])
            agent.restore_identity(self.root, inspection)
            new_token = hmac.new(secret.encode(), agent.PURPOSE, hashlib.sha256).hexdigest()
            self.assertEqual(request('GET', '/status')[0], 403)
            self.assertEqual(request('GET', '/status', token_value=new_token)[0], 200)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__': unittest.main()
