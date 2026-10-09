#!/usr/bin/env python3
"""Local panel update service. Runs only verified releases through the installer."""
import argparse
import fcntl
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import re
import socketserver
import subprocess
import time
import uuid

import runtime

SCRIPT = '/usr/local/lib/remnacust-installer/update-agent.py'
CLI = '/usr/local/bin/remnacust'
CONTAINER_CONTROL = '/run/remnacust-control'
SERVICE = 'remnacust-panel-update.service'
UNIT_ROOT = Path('/etc/systemd/system')
PURPOSE = b'remnacust-panel-update-v1'


class UpdateError(ValueError):
    pass


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+\.\d+\.\d+(?:\.\d+)?', value):
        raise UpdateError('INVALID_VERSION')
    parts = tuple(map(int, value.split('.')))
    if any(part > 2147483647 for part in parts):
        raise UpdateError('INVALID_VERSION')
    return parts + (0,) * (4 - len(parts))


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        data = stream.read(16385)
    if len(data) > 16384:
        raise UpdateError('INVALID_STATE')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise UpdateError('INVALID_STATE')
    return value


def job_id(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise UpdateError('INVALID_REQUEST')
    return value


def setup(root, state_path, compose_path, inspection=None):
    root = root.resolve()
    control = root / 'control'
    if control.is_symlink() or (root / 'update-agent.json').is_symlink():
        raise UpdateError('UNSAFE_PATH')
    control.mkdir(mode=0o700, exist_ok=True)
    control.chmod(0o700)
    state = read_json(state_path)
    if inspection:
        inspected = json.loads(Path(inspection).read_text())
        if isinstance(inspected, list):
            inspected = inspected[0]
        secret = runtime.environment(inspected).get('APP_SECRET', '')
    else:
        env = (Path(state['directory']) / '.env').read_text()
        match = re.search(r'^APP_SECRET=([a-f0-9]{64})$', env, re.M)
        secret = match[1] if match else ''
    if len(secret) < 32:
        raise UpdateError('MISSING_SECRET')
    token = hmac.new(secret.encode(), PURPOSE, hashlib.sha256).hexdigest()
    runtime.write(root / 'update-agent.json', {'token': token})
    config = runtime.load(compose_path)
    for name in state['applications']:
        service = config['services'][name]
        mounts = service.setdefault('volumes', [])
        previous = [mount for mount in mounts if
                    (isinstance(mount, dict) and mount.get('target') == CONTAINER_CONTROL) or
                    (isinstance(mount, str) and CONTAINER_CONTROL in mount.split(':')[1:2])]
        expected = {'type': 'bind', 'source': str(control), 'target': CONTAINER_CONTROL, 'read_only': True}
        if previous and previous != [expected]:
            raise UpdateError('CONTROL_MOUNT_CONFLICT')
        if not previous:
            mounts.append(expected)
    runtime.write(compose_path, config)
    if not (control / 'status.json').exists():
        runtime.write(control / 'status.json', {'active': False, 'phase': 'idle', 'jobId': None,
                                              'targetVersion': None, 'error': None}, mode=0o644)
    quoted_root = json.dumps(str(root)).replace('%', '%%')
    unit = ('[Unit]\nDescription=Remnacust panel updates\nAfter=docker.service\n\n'
            '[Service]\nType=simple\nExecStart=/usr/bin/python3 ' + SCRIPT + ' --root ' + quoted_root + ' serve\n'
            'Restart=on-failure\nRestartSec=3\nUMask=0077\n\n[Install]\nWantedBy=multi-user.target\n')
    runtime.write(UNIT_ROOT / SERVICE, unit, mode=0o644)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', SERVICE], check=True)
    subprocess.run(['systemctl', 'restart', SERVICE], check=True)


class Agent:
    def __init__(self, root):
        self.root = root.resolve()
        self.control = self.root / 'control'

    def state(self):
        return read_json(self.control / 'status.json')

    def save(self, value):
        runtime.write(self.control / 'status.json', value, mode=0o644)

    def installed(self):
        record = read_json(self.root / 'registry/panel.json')
        if record.get('component') != 'panel' or record.get('uninstalled'):
            raise UpdateError('NOT_INSTALLED')
        version(record['version'])
        return record['version']

    def status(self):
        state = self.state()
        if state.get('active') and time.time() - state.get('startedAt', 0) > 60:
            checked_job = state['jobId']
            unit = 'remnacust-panel-update-' + job_id(state['jobId'])
            alive = subprocess.run(['systemctl', 'is-active', '--quiet', unit], timeout=5).returncode == 0
            if not alive:
                # A dead worker must not leave all browsers locked indefinitely.
                with self.lock(False) as lock:
                    if lock:
                        state = self.state()
                        if state.get('active') and state.get('jobId') == checked_job:
                            state.update(active=False, phase='failed', error='INTERRUPTED')
                            self.save(state)
        try:
            current = self.installed()
        except (OSError, ValueError, KeyError):
            current = None
        return {**state, 'available': current is not None, 'installedVersion': current}

    def lock(self, wait=True):
        class Lock:
            def __enter__(inner):
                inner.file = os.fdopen(os.open(self.control / 'update.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), 'a+')
                try:
                    fcntl.flock(inner.file, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
                    return True
                except BlockingIOError:
                    inner.file.close()
                    inner.file = None
                    return False
            def __exit__(inner, *_):
                if inner.file:
                    inner.file.close()
        return Lock()

    def start(self, target, request):
        target_parts, request = version(target), job_id(request)
        with self.lock(False) as locked:
            if not locked:
                state = self.state()
                if state.get('jobId') == request:
                    return state
                raise UpdateError('UPDATE_BUSY')
            state = self.state()
            if state.get('jobId') == request:
                return state
            if state.get('active'):
                raise UpdateError('UPDATE_BUSY')
            if target_parts <= version(self.installed()):
                raise UpdateError('NOT_NEWER')
            state = {'active': True, 'phase': 'queued', 'jobId': request, 'targetVersion': target,
                     'startedAt': time.time(), 'error': None}
            self.save(state)
            try:
                subprocess.run(['systemd-run', '--quiet', '--collect', '--service-type=exec',
                    '--unit=remnacust-panel-update-' + request, '--property=UMask=0077',
                    '--property=RuntimeMaxSec=7200', '/usr/bin/python3', SCRIPT,
                    '--root', str(self.root), 'worker', '--job', request], check=True, timeout=15)
            except (OSError, subprocess.SubprocessError):
                state.update(active=False, phase='failed', error='START_FAILED')
                self.save(state)
                raise UpdateError('START_FAILED')
            return state

    def work(self, request):
        request = job_id(request)
        with self.lock() as locked:
            state = self.state()
            if state.get('jobId') != request or not state.get('active'):
                return
            info = self.control / ('release-' + request + '.json')
            entry = self.control / ('release-' + request + '.sh')
            try:
                log_dir = self.root / 'logs'
                log_dir.mkdir(mode=0o700, exist_ok=True)
                fd = os.open(log_dir / ('panel-update-' + request + '.log'), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as log:
                    env = {**os.environ, 'REMNACUST_ROOT': str(self.root), 'REMNACUST_RELEASE_INFO_FILE': str(info),
                       'REMNACUST_RELEASE_ENTRY_FILE': str(entry)}
                    state['phase'] = 'checking'
                    self.save(state)
                    subprocess.run([CLI, '--check-release', '--version', 'latest'], env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True, timeout=900)
                    release = read_json(info)
                    if release['panelVersion'] != state['targetVersion']:
                        raise UpdateError('RELEASE_NOT_READY')
                    installer = release['installerVersion']
                    if not re.fullmatch(r'\d+\.\d+\.\d+', installer):
                        raise UpdateError('INVALID_RELEASE')
                    state['phase'] = 'updating'
                    self.save(state)
                    if entry.is_symlink() or not entry.is_file():
                        raise UpdateError('INVALID_RELEASE')
                    subprocess.run(['/usr/bin/bash', str(entry), 'upgrade-panel', '--version', installer, '--yes'], env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True)
                    if self.installed() != state['targetVersion']:
                        raise UpdateError('VERSION_MISMATCH')
                    state.update(active=False, phase='completed', error=None)
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                state.update(active=False, phase='failed', error=str(error) if isinstance(error, UpdateError) else 'UPDATE_FAILED')
            finally:
                self.save(state)
                info.unlink(missing_ok=True)
                entry.unlink(missing_ok=True)


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address


def serve(agent):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def reply(self, code, data):
            body = json.dumps(data).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def handle_request(self):
            self.connection.settimeout(5)
            token = read_json(agent.root / 'update-agent.json')['token']
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                return self.reply(403, {'error': 'FORBIDDEN'})
            try:
                if self.command == 'GET' and self.path == '/status':
                    return self.reply(200, agent.status())
                if self.command == 'POST' and self.path == '/update':
                    lengths = self.headers.get_all('Content-Length', [])
                    if len(lengths) != 1 or self.headers.get('Transfer-Encoding') or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 256:
                        raise UpdateError('INVALID_REQUEST')
                    data = json.loads(self.rfile.read(int(lengths[0])))
                    if not isinstance(data, dict) or set(data) != {'targetVersion', 'requestId'}:
                        raise UpdateError('INVALID_REQUEST')
                    agent.start(data['targetVersion'], data['requestId'])
                    return self.reply(202, agent.status())
                self.reply(404, {'error': 'NOT_FOUND'})
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                self.reply(409 if str(error) == 'UPDATE_BUSY' else 400,
                           {'error': str(error) if isinstance(error, UpdateError) else 'INVALID_REQUEST'})
        do_GET = handle_request
        do_POST = handle_request
    socket_path = agent.control / 'update.sock'
    if socket_path.exists() or socket_path.is_symlink():
        if socket_path.is_symlink() or not socket_path.is_socket():
            raise UpdateError('UNSAFE_SOCKET')
        socket_path.unlink()
    with UnixServer(str(socket_path), Handler) as server:
        socket_path.chmod(0o600)
        server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/opt/remnacust'))
    parser.add_argument('operation', choices=['serve', 'worker', 'setup'])
    parser.add_argument('--job'); parser.add_argument('--state'); parser.add_argument('--compose'); parser.add_argument('--inspect')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run the panel update service as root')
    if args.operation == 'setup':
        setup(args.root, args.state, args.compose, args.inspect)
    elif args.operation == 'worker':
        Agent(args.root).work(args.job)
    else:
        serve(Agent(args.root))
