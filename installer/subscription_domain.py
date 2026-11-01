"""Synchronize one public subscription origin in a registered panel deployment."""
from contextlib import contextmanager
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import uuid
from urllib.parse import urlsplit

import runtime

KEY = 'SUB_PUBLIC_DOMAIN'
ASSIGNMENT = re.compile(r'^(?:export[ \t]+)?SUB_PUBLIC_DOMAIN[ \t]*=.*$', re.M)


class DomainError(ValueError):
    pass


def normalize(value):
    if not isinstance(value, str) or not value or len(value) > 512 or re.search(r'[\s\\%?#\x00-\x1f\x7f]', value):
        raise DomainError('DOMAIN_INVALID')
    url = urlsplit(value if '://' in value else 'https://' + value)
    if url.scheme != 'https' or url.username or url.password or url.port not in (None, 443) or not url.hostname:
        raise DomainError('DOMAIN_INVALID')
    host = url.hostname.encode('idna').decode().lower()
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise DomainError('DOMAIN_INVALID')
    if (len(host) > 253 or '.' not in host or host.endswith(('.', '.local', '.localhost'))
            or all(re.fullmatch(r'(?:0x[0-9a-f]+|[0-9]+)', part) for part in host.split('.'))
            or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part) for part in host.split('.'))):
        raise DomainError('DOMAIN_INVALID')
    path = url.path[:-1] if url.path.endswith('/') else url.path
    if len(path) > 240 or '..' in path or (path and not re.fullmatch(r'/(?:[a-zA-Z0-9._~-]+(?:/[a-zA-Z0-9._~-]+)*)', path)):
        raise DomainError('DOMAIN_INVALID')
    return host + path


def read(path, optional=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        raise DomainError('DOMAIN_UNSAFE_PATH')
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if optional:
            return None
        raise
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024 or info.st_nlink != 1
                or info.st_uid not in {0, os.geteuid()} or info.st_mode & 0o022):
            raise DomainError('DOMAIN_UNSAFE_PATH')
        data = stream.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise DomainError('DOMAIN_UNSAFE_PATH')
    return data


@contextmanager
def locked(root):
    path = root / '.installer.lock'
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, 'a+') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise DomainError('DOMAIN_UNSAFE_PATH')
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DomainError('UPDATE_BUSY') from None
        yield


def context(root):
    state = json.loads(read(root / 'registry/panel.json'))
    if state.get('component') != 'panel' or state.get('uninstalled'):
        raise DomainError('DOMAIN_NOT_MANAGED')
    directory = Path(state['directory'])
    if not directory.is_absolute() or directory.resolve() != directory or directory.is_symlink():
        raise DomainError('DOMAIN_UNSAFE_PATH')
    names = state['applications']
    sources = state['composeFiles']
    if (not isinstance(names, list) or not 1 <= len(names) <= 16
            or not all(isinstance(name, str) and re.fullmatch(r'[a-zA-Z0-9_.-]{1,128}', name) for name in names)
            or not isinstance(sources, list) or not 1 <= len(sources) <= 8):
        raise DomainError('DOMAIN_NOT_MANAGED')
    files = {directory / '.env': read(directory / '.env', optional=True)}
    configs = {}
    for source in sources:
        path = directory / source
        data = read(path)
        try:
            config = json.loads(data)
        except (ValueError, UnicodeError):
            raise DomainError('DOMAIN_COMPOSE_UNSUPPORTED') from None
        if not isinstance(config.get('services'), dict):
            raise DomainError('DOMAIN_COMPOSE_UNSUPPORTED')
        files[path] = data
        configs[path] = config
        for name in names:
            service = config['services'].get(name)
            if not service:
                continue
            env_files = service.get('env_file') or []
            if not isinstance(env_files, list):
                env_files = [env_files]
            for entry in env_files:
                env_path = directory / (entry['path'] if isinstance(entry, dict) else entry)
                files[env_path] = read(env_path)
    if len(files) > 32:
        raise DomainError('DOMAIN_NOT_MANAGED')
    return directory, names, files, configs


def env_value(data):
    if data is None:
        return None
    matches = list(ASSIGNMENT.finditer(data.decode('utf-8')))
    if not matches:
        return None
    value = matches[-1][0].split('=', 1)[1].strip()
    if value[:1] in ('"', "'"):
        quote = value[0]
        end = value.find(quote, 1)
        tail = value[end + 1:].strip() if end >= 0 else ''
        if end < 0 or (tail and not tail.startswith('#')):
            raise DomainError('DOMAIN_INVALID')
        value = value[1:end]
    else:
        value = re.split(r'[ \t]+#', value, maxsplit=1)[0].strip()
    return value


def snapshot(directory, names, files, configs):
    value = env_value(files[directory / '.env'])
    if value is None:
        for path, data in files.items():
            if path not in configs:
                value = env_value(data) or value
        for config in configs.values():
            for name in names:
                inline = runtime.compose_environment(config['services'].get(name, {}).get('environment'))
                if KEY in inline:
                    value = inline[KEY]
    valid = True
    try:
        value = normalize(value)
    except (ValueError, UnicodeError):
        value, valid = None, False
    digest = hashlib.sha256()
    for path, data in sorted(files.items()):
        digest.update(str(path).encode() + b'\x00' + (hashlib.sha256(data).digest() if data is not None else b'missing'))
    return {'value': value, 'revision': digest.hexdigest(), 'valid': valid}


def synchronize(root, change=None):
    root = Path(root).resolve()
    with locked(root):
        directory, names, files, configs = context(root)
        before = snapshot(directory, names, files, configs)
        if change is None:
            return before
        if (not isinstance(change, dict) or set(change) != {'value', 'expectedRevision'}
                or change['expectedRevision'] != before['revision']):
            raise DomainError('DOMAIN_CHANGED')
        value = normalize(change['value']) if change['value'] is not None else None
        modified = {}
        for path, data in files.items():
            if path in configs:
                config = configs[path]
                for name in names:
                    service = config['services'].get(name)
                    if service is None:
                        continue
                    inline = runtime.compose_environment(service.get('environment'))
                    if KEY in inline or not service.get('env_file'):
                        if value is None:
                            inline.pop(KEY, None)
                        else:
                            inline[KEY] = value
                        service['environment'] = inline
                text = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
            else:
                text = (data or b'').decode('utf-8')
                if path != directory / '.env' and not ASSIGNMENT.search(text):
                    continue
                text = ASSIGNMENT.sub('', text) if value is None else ASSIGNMENT.sub(KEY + '=' + value, text)
                if value is not None and not ASSIGNMENT.search(text):
                    text = text.rstrip('\n') + '\n' + KEY + '=' + value + '\n'
            if text.encode() != data:
                modified[path] = text.encode()
        if not modified:
            return before
        backup = root / 'backups/panel' / ('subscription-domain-' + uuid.uuid4().hex)
        if backup.resolve() != backup:
            raise DomainError('DOMAIN_UNSAFE_PATH')
        backup.mkdir(mode=0o700, parents=True)
        runtime.write(backup / 'manifest.json', {'files': [
            {'path': str(path), 'backup': str(index) + '.before' if files[path] is not None else None,
             'sha256': hashlib.sha256(files[path]).hexdigest() if files[path] is not None else None}
            for index, path in enumerate(modified)
        ]})
        written = []
        try:
            for index, (path, data) in enumerate(modified.items()):
                if read(path, optional=True) != files[path]:
                    raise DomainError('DOMAIN_CHANGED')
                if files[path] is not None:
                    runtime.write(backup / (str(index) + '.before'), files[path].decode('utf-8'))
                runtime.write(path, data.decode('utf-8'))
                written.append(path)
        except BaseException:
            for path in reversed(written):
                if read(path, optional=True) == modified[path]:
                    if files[path] is None:
                        path.unlink()
                    else:
                        runtime.write(path, files[path].decode('utf-8'))
            raise
        return snapshot(*context(root))
