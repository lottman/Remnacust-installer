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
import stat
import socketserver
import subprocess
import time
import uuid
from urllib.request import Request, urlopen

import runtime
import subscription_pages
import subscription_domain

SCRIPT = str(Path(__file__).resolve())
CLI = '/usr/local/bin/remnacust'
CONTAINER_CONTROL = '/run/remnacust-control'
SERVICE = 'remnacust-panel-update.service'
UNIT_ROOT = Path('/etc/systemd/system')
PURPOSE = b'remnacust-panel-update-v1'
STAGES = ('checking', 'download', 'preparation', 'backup', 'applying', 'readiness', 'verifying', 'cleanup')
MAX_LOG_BYTES = 1024 * 1024


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


def private_log(root, name, previous_pattern):
    directory = root / 'logs'
    if directory.is_symlink():
        raise ValueError('Invalid private log directory')
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    path = directory / name
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        for previous in directory.iterdir():
            if previous != path and re.fullmatch(previous_pattern, previous.name) and not previous.is_symlink() and previous.is_file():
                previous.unlink()
    except OSError:
        os.close(fd)
        raise
    return os.fdopen(fd, 'wb')


def private_log_event(output, event, detail):
    output.write(('[' + time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + '] ' + event + ' ' + detail + '\n').encode('utf-8', errors='replace'))
    output.flush()


def private_log_failure(path, error):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
        with os.fdopen(fd, 'wb') as output:
            private_log_event(output, 'FAILED', type(error).__name__ + ': ' + str(error))
            private_log_event(output, 'LOG', str(path))
    except OSError:
        pass


def start_failure_log(root, name, pattern, error):
    try:
        with private_log(root, name, pattern) as output:
            private_log_event(output, 'FAILED', type(error).__name__ + ': ' + str(error))
        return str(root / 'logs' / name)
    except OSError:
        return None


def download_log(root, filename):
    directory = root / 'logs'
    if directory.is_symlink():
        raise UpdateError('LOG_UNAVAILABLE')
    path = directory / filename
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise UpdateError('LOG_UNAVAILABLE')
            truncated = metadata.st_size > MAX_LOG_BYTES
            source.seek(max(0, metadata.st_size - MAX_LOG_BYTES))
            raw = source.read(MAX_LOG_BYTES)
    except OSError as error:
        raise UpdateError('LOG_UNAVAILABLE') from error
    if truncated:
        raw = raw.partition(b'\n')[2]
    raw = raw[:raw.rfind(b'\n') + 1]
    text = raw.decode('utf-8', errors='replace')
    if truncated:
        ending = re.search(r'-----END [A-Z ]*PRIVATE KEY-----', text)
        beginning = re.search(r'-----BEGIN [A-Z ]*PRIVATE KEY-----', text)
        if ending and (not beginning or ending.start() < beginning.start()):
            text = '[REDACTED PRIVATE KEY]' + text[ending.end():]
    secrets = []
    try:
        secrets.append(read_json(root / 'update-agent.json')['token'])
    except (OSError, ValueError, KeyError):
        pass
    directories = {root / 'panel', root / 'node', root / 'subscription-page'}
    registry = root / 'registry'
    records = list(registry.glob('*.json'))[:64] + list((registry / 'subscription-pages').glob('*.json'))[:32]
    for record in records:
        try:
            value = read_json(record)
            if isinstance(value.get('directory'), str):
                directories.add(Path(value['directory']))
        except (OSError, ValueError, KeyError, TypeError):
            pass
    for directory in directories:
        try:
            descriptor = os.open(directory / '.env', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, 'rb') as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    continue
                environment = source.read(MAX_LOG_BYTES).decode('utf-8', errors='replace')
            for match in re.finditer(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$', environment, re.M):
                if re.search(r'secret|password|token|private|credential|api_?key|database_url|salt|dsn', match[1], re.I):
                    value = match[2].strip().strip('\"\'')
                    if len(value) >= 4:
                        secrets.append(value)
        except OSError:
            pass
    for secret in sorted({value for value in secrets if isinstance(value, str) and len(value) >= 4}, key=len, reverse=True):
        text = text.replace(secret, '[REDACTED]')
    text = re.sub(r'(?im)(authorization\s*[:=]\s*(?:bearer|basic)\s+)\S+', r'\1[REDACTED]', text)
    text = re.sub(r'''(?im)((?:["'])?\b[A-Za-z0-9_]*(?:SECRET|PASSWORD|TOKEN|PRIVATE_?KEY|CREDENTIAL|API_?KEY|AUTHORIZATION)[A-Za-z0-9_]*(?:["'])?\s*[:=]\s*)[^\r\n]+''', r'\1[REDACTED]', text)
    text = re.sub(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)', '[REDACTED PRIVATE KEY]', text)
    text = re.sub(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[REDACTED]', text)
    text = re.sub(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@', r'\1[REDACTED]@', text)
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = ''.join(character for character in text if character in '\n\t' or ord(character) >= 32 and ord(character) != 127)
    if truncated:
        text = '[Download contains the last 1 MiB. The complete private log remains on the server.]\n' + text
    return {'filename': filename, 'content': text, 'truncated': truncated}


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
    unit = ('[Unit]\nDescription=Remnacust maintenance API (updates on request)\nAfter=docker.service\n\n'
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

    def log(self, request, page=None):
        request = job_id(request)
        if page is None:
            state = self.state()
            if state.get('jobId') != request:
                raise UpdateError('LOG_UNAVAILABLE')
            filename = 'panel-update-' + request + '.log'
        else:
            if not isinstance(page, str) or not re.fullmatch('[a-f0-9]{24}', page):
                raise UpdateError('INVALID_REQUEST')
            state = read_json(self.control / ('page-' + page + '.json'))
            if state.get('requestId') != request:
                raise UpdateError('LOG_UNAVAILABLE')
            filename = 'page-' + page + '-' + request + '.log'
        return download_log(self.root, filename)

    def pages(self):
        result = subscription_pages.listing(self.root)
        for item in result:
            try:
                job = read_json(self.control / ('page-' + item['id'] + '.json'))
                if job.get('phase') in ('queued', 'running') and time.time() - job.get('startedAt', 0) > 7200:
                    job.update(phase='failed', error='INTERRUPTED')
                item['job'] = {key: job.get(key) for key in ('requestId', 'operation', 'phase', 'error', 'logPath')}
            except FileNotFoundError:
                item['job'] = None
        return {'pages': result}

    def subscription_domain(self, change=None):
        with self.lock(False) as acquired:
            if not acquired or self.state().get('active'):
                raise UpdateError('UPDATE_BUSY')
            try:
                return subscription_domain.synchronize(self.root, change)
            except subscription_domain.DomainError as error:
                raise UpdateError(str(error)) from None

    def page_start(self, page, operation, request):
        request = job_id(request)
        if operation not in ('start', 'stop', 'restart', 'upgrade'):
            raise UpdateError('INVALID_REQUEST')
        item = subscription_pages.selected(self.root, page, allow_discovered=True)
        if operation == 'upgrade' and item.get('managed') is False:
            raise UpdateError('PAGE_MIGRATION_REQUIRED')
        with self.lock(False) as locked:
            if not locked or self.state().get('active'):
                raise UpdateError('UPDATE_BUSY')
            path = self.control / ('page-' + page + '.json')
            try:
                previous = read_json(path)
                if previous.get('requestId') == request:
                    if previous.get('operation') != operation:
                        raise UpdateError('INVALID_REQUEST')
                    return previous
                if previous.get('phase') in ('queued', 'running') and time.time() - previous.get('startedAt', 0) < 7200:
                    raise UpdateError('UPDATE_BUSY')
            except FileNotFoundError:
                pass
            state = {'page': page, 'operation': operation, 'requestId': request, 'phase': 'queued', 'startedAt': time.time(), 'error': None}
            runtime.write(path, state)
            try:
                subprocess.run(['systemd-run', '--quiet', '--collect', '--service-type=exec', '--unit=remnacust-page-' + request,
                    '--property=UMask=0077', '--property=RuntimeMaxSec=7200', '/usr/bin/python3', '-B', SCRIPT,
                    '--root', str(self.root), 'page-worker', '--page-id', page, '--job', request], check=True, timeout=15)
            except (OSError, subprocess.SubprocessError) as error:
                state.update(phase='failed', error='START_FAILED', logPath=start_failure_log(
                    self.root, 'page-' + page + '-' + request + '.log', 'page-' + page + r'-[a-f0-9-]{36}\.log', error))
                runtime.write(path, state)
                raise UpdateError('START_FAILED')
            return state

    def page_work(self, page, request):
        request = job_id(request)
        if not isinstance(page, str) or not re.fullmatch('[a-f0-9]{24}', page):
            raise UpdateError('INVALID_REQUEST')
        path = self.control / ('page-' + page + '.json')
        with self.lock():
            state = read_json(path)
            if state.get('requestId') != request or state.get('phase') != 'queued':
                return
            log = self.root / 'logs' / ('page-' + page + '-' + request + '.log')
            log_created = False
            try:
                output = private_log(self.root, log.name, 'page-' + page + r'-[a-f0-9-]{36}\.log')
                log_created = True
                state['logPath'] = str(log)
                private_log_event(output, 'START', 'page=' + page + ' operation=' + str(state.get('operation')))
                item = subscription_pages.selected(self.root, page, allow_discovered=True)
                operation = state['operation']
                if operation == 'upgrade' and item.get('managed') is False:
                    raise UpdateError('PAGE_MIGRATION_REQUIRED')
                if operation not in ('start', 'stop', 'restart', 'upgrade'):
                    raise UpdateError('INVALID_REQUEST')
                state.update(phase='running')
                runtime.write(path, state)
                with output:
                    args = [CLI, 'upgrade-subscription-page', '--version', 'latest'] if operation == 'upgrade' else [CLI, 'manage-subscription-page', '--page-operation', operation]
                    subprocess.run([*args, '--page-id', page, '--yes'], stdin=subprocess.DEVNULL, stdout=output, stderr=output, check=True, timeout=7100)
                    private_log_event(output, 'COMPLETED', 'page=' + page)
                state.update(phase='completed', error=None)
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                if log_created:
                    output.close()
                    private_log_failure(log, error)
                state.update(phase='failed', error='PAGE_OPERATION_FAILED')
            state['finishedAt'] = time.time()
            runtime.write(path, state)

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
            except (OSError, subprocess.SubprocessError) as error:
                state.update(active=False, phase='failed', error='START_FAILED', logPath=start_failure_log(
                    self.root, 'panel-update-' + request + '.log', r'panel-update-[a-f0-9-]{36}\.log', error))
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
            log_created = False
            log_path = self.root / 'logs' / ('panel-update-' + request + '.log')
            try:
                output = private_log(self.root, log_path.name, r'panel-update-[a-f0-9-]{36}\.log')
                log_created = True
                state['logPath'] = str(log_path)
                with output as log:
                    private_log_event(log, 'START', 'requested-panel=' + state['targetVersion'] + ' job=' + request)
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
                    private_log_event(log, 'COMPLETED', 'panel=' + state['targetVersion'])
                    try:
                        progress = read_json(self.control / ('progress-' + request + '.json'))
                        progress['durations'][progress['stage']] = max(0, time.time() - progress['stageStartedAt'])
                        runtime.write(self.control / 'update-timings.json', {'durations': progress['durations']})
                    except (OSError, ValueError, KeyError):
                        pass
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                # The output stream has closed by this point. Preserve Python/network
                # failures too, without copying private diagnostics into public status.
                if log_created:
                    private_log_failure(log_path, error)
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
                if self.command == 'GET' and self.path.startswith('/logs/panel/'):
                    return self.reply(200, agent.log(self.path[len('/logs/panel/'):]))
                if self.command == 'GET' and self.path.startswith('/logs/page/'):
                    parts = self.path[len('/logs/page/'):].split('/')
                    if len(parts) != 2:
                        raise UpdateError('INVALID_REQUEST')
                    return self.reply(200, agent.log(parts[1], parts[0]))
                if self.command == 'GET' and self.path == '/pages':
                    return self.reply(200, agent.pages())
                if self.command == 'GET' and self.path == '/subscription-domain':
                    return self.reply(200, agent.subscription_domain())
                if self.command == 'POST' and self.path == '/subscription-domain':
                    lengths = self.headers.get_all('Content-Length', [])
                    if len(lengths) != 1 or self.headers.get('Transfer-Encoding') or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 1024:
                        raise UpdateError('INVALID_REQUEST')
                    data = json.loads(self.rfile.read(int(lengths[0])))
                    if not isinstance(data, dict) or set(data) != {'value', 'expectedRevision'}:
                        raise UpdateError('INVALID_REQUEST')
                    return self.reply(200, agent.subscription_domain(data))
                if self.command == 'POST' and self.path == '/pages/action':
                    lengths = self.headers.get_all('Content-Length', [])
                    if len(lengths) != 1 or self.headers.get('Transfer-Encoding') or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 256:
                        raise UpdateError('INVALID_REQUEST')
                    data = json.loads(self.rfile.read(int(lengths[0])))
                    if not isinstance(data, dict) or set(data) != {'pageId', 'operation', 'requestId'}:
                        raise UpdateError('INVALID_REQUEST')
                    agent.page_start(data['pageId'], data['operation'], data['requestId'])
                    return self.reply(202, agent.pages())
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
    parser.add_argument('operation', choices=['serve', 'worker', 'page-worker', 'setup', 'restore-identity', 'progress'])
    parser.add_argument('--page-id')
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
    elif args.operation == 'page-worker':
        Agent(args.root).page_work(args.page_id, args.job)
    else:
        serve(Agent(args.root))
