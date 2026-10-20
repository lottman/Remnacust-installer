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
from urllib.request import Request, urlopen

import runtime

SCRIPT = str(Path(__file__).resolve())
CLI = '/usr/local/bin/remnacust'
CONTAINER_CONTROL = '/run/remnacust-control'
SERVICE = 'remnacust-panel-update.service'
UNIT_ROOT = Path('/etc/systemd/system')
PURPOSE = b'remnacust-panel-update-v1'
STAGES = ('checking', 'download', 'preparation', 'backup', 'applying', 'readiness', 'verifying', 'cleanup')


def record_progress(root, request, stage, label, event):
    """Publish bounded step events, never command arguments or raw process output."""
    request = job_id(request)
    root = root.resolve()
    state = read_json(root / 'control/status.json')
    if state.get('jobId') != request or not state.get('active'):
        return
    if stage not in STAGES or event not in ('running', 'done', 'failed'):
        raise UpdateError('INVALID_PROGRESS')
    path = root / 'control' / ('progress-' + request + '.json')
    now = time.time()
    try:
        progress = read_json(path)
    except FileNotFoundError:
        progress = {'stage': stage, 'stageStartedAt': now, 'events': [], 'durations': {}}
    previous = progress['stage']
    # Optional/repeated substeps cannot move the overall operation backwards.
    if STAGES.index(stage) > STAGES.index(previous):
        progress['durations'][previous] = max(0, now - progress['stageStartedAt'])
        progress.update(stage=stage, stageStartedAt=now)
    label = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', label)[:120]
    progress['events'] = (progress['events'] + [{'at': now, 'label': label, 'event': event}])[-24:]
    progress['updatedAt'] = now
    runtime.write(path, progress, mode=0o644)


def update_progress(root, state):
    request = state.get('jobId')
    if not request:
        return None
    try:
        progress = read_json(root / 'control' / ('progress-' + job_id(request) + '.json'))
    except (OSError, ValueError, KeyError):
        return None
    now = time.time()
    index = STAGES.index(progress['stage'])
    completed = state.get('phase') == 'completed'
    remaining = None
    if state.get('active'):
        try:
            baseline = read_json(root / 'control/update-timings.json')
            durations = baseline['durations']
            if all(stage in durations for stage in STAGES[index:]):
                remaining = round(max(0, sum(durations[stage] for stage in STAGES[index:]) - (now - progress['stageStartedAt'])))
                if remaining == 0:
                    remaining = None  # A slower run must not display a permanent "0 seconds".
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return {'stage': progress['stage'], 'stageIndex': index + 1, 'stageCount': len(STAGES),
            'completedStages': len(STAGES) if completed else index,
            'percent': 100 if completed else round(index * 100 / len(STAGES)),
            'startedAt': state.get('startedAt'), 'updatedAt': progress['updatedAt'],
            'elapsedSeconds': round(max(0, (state.get('finishedAt') or now) - state.get('startedAt', now))),
            'estimatedRemainingSeconds': remaining, 'events': progress['events']}


class UpdateError(ValueError):
    pass


def latest_installer_release():
    """Resolve mutable Latest once, then let the CLI verify that exact tag."""
    repository = os.environ.get('REMNACUST_REPOSITORY', 'lottman/Remnacust-installer')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise UpdateError('INVALID_RELEASE')
    request = Request(
        f'https://api.github.com/repos/{repository}/releases/latest?remnacust_check={uuid.uuid4().hex}',
        headers={'Accept': 'application/vnd.github+json', 'Cache-Control': 'no-cache',
                 'User-Agent': 'Remnacust-update-agent'},
    )
    with urlopen(request, timeout=15) as response:
        raw = response.read(256 * 1024 + 1)
    if len(raw) > 256 * 1024:
        raise UpdateError('INVALID_RELEASE')
    release = json.loads(raw)
    if not isinstance(release, dict):
        raise UpdateError('INVALID_RELEASE')
    tag = release.get('tag_name')
    if (not isinstance(tag, str) or not re.fullmatch(r'v\d+\.\d+\.\d+', tag)
            or release.get('draft') is not False or release.get('prerelease') is not False):
        raise UpdateError('INVALID_RELEASE')
    version(tag[1:])
    return tag[1:]


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
            '[Service]\nType=simple\nExecStart=/usr/bin/python3 -B ' + json.dumps(SCRIPT).replace('%', '%%') + ' --root ' + quoted_root + ' serve\n'
            'Restart=on-failure\nRestartSec=3\nUMask=0077\n\n[Install]\nWantedBy=multi-user.target\n')
    runtime.write(UNIT_ROOT / SERVICE, unit, mode=0o644)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', SERVICE], check=True)
    subprocess.run(['systemctl', 'restart', SERVICE], check=True)


def restore_identity(root, inspection):
    """Rekey an already configured agent; requests load this token each time."""
    root = root.resolve()
    target = root / 'update-agent.json'
    if target.is_symlink() or (root / 'control').is_symlink():
        raise UpdateError('UNSAFE_PATH')
    if not target.exists():
        return
    read_json(target)
    secret = runtime.environment(runtime.inspect_one(inspection)).get('APP_SECRET', '')
    if not 32 <= len(secret) <= 4096 or any(ch in secret for ch in ['\r', '\n', '\x00']):
        raise UpdateError('MISSING_SECRET')
    token = hmac.new(secret.encode(), PURPOSE, hashlib.sha256).hexdigest()
    runtime.write(target, {'token': token})



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
                            state.update(active=False, phase='failed', error='INTERRUPTED', finishedAt=time.time())
                            self.save(state)
        try:
            current = self.installed()
        except (OSError, ValueError, KeyError):
            current = None
        return {**state, 'available': current is not None, 'installedVersion': current,
                'progress': update_progress(self.root, state)}

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
            # One bounded live journal is sufficient; the private raw logs retain history.
            for previous in self.control.glob('progress-*.json'):
                try:
                    job_id(previous.name[len('progress-'):-len('.json')])
                    if not previous.is_symlink() and previous.is_file():
                        previous.unlink()
                except (OSError, ValueError):
                    pass
            state = {'active': True, 'phase': 'queued', 'jobId': request, 'targetVersion': target,
                     'startedAt': time.time(), 'error': None}
            self.save(state)
            try:
                subprocess.run(['systemd-run', '--quiet', '--collect', '--service-type=exec',
                    '--unit=remnacust-panel-update-' + request, '--property=UMask=0077',
                    '--property=RuntimeMaxSec=7200', '/usr/bin/python3', '-B', SCRIPT,
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
                    env = {**os.environ, 'REMNACUST_ROOT': str(self.root), 'REMNACUST_UPDATE_JOB': request, 'REMNACUST_RELEASE_INFO_FILE': str(info),
                       'REMNACUST_RELEASE_ENTRY_FILE': str(entry)}
                    state['phase'] = 'checking'
                    self.save(state)
                    record_progress(self.root, request, 'checking', 'Проверка выпуска', 'running')
                    installer = latest_installer_release()
                    subprocess.run([CLI, '--check-release', '--version', installer], env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True, timeout=900)
                    release = read_json(info)
                    resolved = release['panelVersion']
                    version(resolved)
                    log.write(f"Verified installer {installer}: panel {resolved}; requested panel {state['targetVersion']}\n".encode())
                    log.flush()
                    if version(resolved) < version(state['targetVersion']):
                        raise UpdateError('RELEASE_NOT_READY')
                    if version(resolved) <= version(self.installed()):
                        raise UpdateError('NOT_NEWER')
                    if release['installerVersion'] != installer:
                        raise UpdateError('INVALID_RELEASE')
                    if entry.is_symlink() or not entry.is_file():
                        raise UpdateError('INVALID_RELEASE')
                    # Browser notifications may predate a newer published release.
                    state.update(requestedVersion=state['targetVersion'], targetVersion=resolved, phase='updating')
                    self.save(state)
                    record_progress(self.root, request, 'checking', 'Выпуск проверен: панель ' + resolved, 'done')
                    subprocess.run(['/usr/bin/bash', str(entry), 'upgrade-panel', '--version', installer, '--yes'], env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True)
                    if self.installed() != state['targetVersion']:
                        raise UpdateError('VERSION_MISMATCH')
                    record_progress(self.root, request, 'cleanup', 'Обновление завершено', 'done')
                    state.update(active=False, phase='completed', error=None)
                    try:
                        progress = read_json(self.control / ('progress-' + request + '.json'))
                        progress['durations'][progress['stage']] = max(0, time.time() - progress['stageStartedAt'])
                        runtime.write(self.control / 'update-timings.json', {'durations': progress['durations']})
                    except (OSError, ValueError, KeyError):
                        pass
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                try:
                    progress = update_progress(self.root, state)
                    record_progress(self.root, request, progress['stage'] if progress else 'checking',
                                    'Обновление не завершено', 'failed')
                except (OSError, ValueError, KeyError):
                    pass
                state.update(active=False, phase='failed', error=str(error) if isinstance(error, UpdateError) else 'UPDATE_FAILED')
            finally:
                state['finishedAt'] = time.time()
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
    parser.add_argument('operation', choices=['serve', 'worker', 'setup', 'restore-identity', 'progress'])
    parser.add_argument('--stage'); parser.add_argument('--label'); parser.add_argument('--event')
    parser.add_argument('--job'); parser.add_argument('--state'); parser.add_argument('--compose'); parser.add_argument('--inspect')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run the panel update service as root')
    if args.operation == 'progress':
        record_progress(args.root, args.job, args.stage, args.label, args.event)
    elif args.operation == 'setup':
        setup(args.root, args.state, args.compose, args.inspect)
    elif args.operation == 'restore-identity':
        restore_identity(args.root, args.inspect)
    elif args.operation == 'worker':
        Agent(args.root).work(args.job)
    else:
        serve(Agent(args.root))
