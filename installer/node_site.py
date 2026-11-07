import argparse
import ast
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import sys
import uuid


CATALOG_PATH = Path(__file__).with_name('node_site_catalog.py')
MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_MANIFEST_BYTES = 16384
MAX_TEMPLATES = 64
MAX_SITE_FILES = 64
MAX_FILE_BYTES = 512 * 1024
MAX_EXISTING_FILES = 512
MAX_EXISTING_BYTES = 64 * 1024 * 1024
MAX_EXISTING_DEPTH = 8
STATE_NAME = '.node-site.json'
JOURNAL_NAME = '.node-site-transaction.json'
LOCK_NAME = '.node-site.lock'
RECEIPT_NAME = 'node-site-backup.json'
OLD_STUB = b'<!doctype html><html lang="en"><meta charset="utf-8"><title>Service</title><p>Service is available.</p></html>\n'
IDENTIFIER = re.compile(r'[a-z][a-z0-9-]{0,47}\Z')
HEX = re.compile(r'[a-f0-9]{64}\Z')
TOKEN = re.compile(r'[a-f0-9]{32}\Z')
EXTENSIONS = {'.html', '.css', '.js', '.svg', '.txt', '.json', '.xml', '.webmanifest'}


class SiteError(ValueError):
    pass


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise SiteError('DUPLICATE_JSON_KEY')
        result[key] = value
    return result


def _json(data):
    try:
        if isinstance(data, bytes):
            data = data.decode('utf-8')
        return json.loads(data, object_pairs_hook=_pairs)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise SiteError('INVALID_JSON') from error


def _name(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 180 or '\\' in value:
        raise SiteError('UNSAFE_ASSET_PATH')
    path = PurePosixPath(value)
    if (path.is_absolute() or str(path) != value or len(path.parts) > 5 or
            any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', part) or
                part in {'.', '..'} or part.endswith('.') or
                re.fullmatch(r'(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part, re.I)
                for part in path.parts) or path.suffix.lower() not in EXTENSIONS):
        raise SiteError('UNSAFE_ASSET_PATH')
    return value


def _domain(value):
    if not isinstance(value, str) or not value or len(value) > 253:
        raise SiteError('INVALID_DOMAIN')
    try:
        result = value.rstrip('.').encode('idna').decode('ascii').lower()
    except UnicodeError as error:
        raise SiteError('INVALID_DOMAIN') from error
    if (len(result) > 253 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label)
                                 for label in result.split('.'))):
        raise SiteError('INVALID_DOMAIN')
    return result


def _safe(path, directory=None):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts or path == Path(path.anchor):
        raise SiteError('UNSAFE_SITE_PATH')
    for candidate in [*reversed(path.parents), path]:
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise SiteError('SITE_SYMLINK')
        if candidate != path and not stat.S_ISDIR(info.st_mode):
            raise SiteError('UNSAFE_SITE_ANCESTOR')
        if (os.name == 'posix' and stat.S_ISDIR(info.st_mode) and
                info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
            raise SiteError('SITE_WRITABLE_ANCESTOR')
        if candidate == path and directory is True and not stat.S_ISDIR(info.st_mode):
            raise SiteError('SITE_NOT_DIRECTORY')
        if candidate == path and directory is False and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
            raise SiteError('SITE_NOT_REGULAR_FILE')
    return path


def _mkdir(path):
    path = _safe(path, True)
    for candidate in reversed([path, *path.parents]):
        if not candidate.exists():
            _make_directory(candidate, 0o755)
        if candidate != Path(candidate.anchor):
            _safe(candidate, True)
    return path


def _make_directory(path, mode):
    with _parent(path) as parent:
        if parent is None:
            path.mkdir(mode=mode)
        else:
            os.mkdir(path.name, mode=mode, dir_fd=parent)
    _safe(path, True)


def _read(path, limit):
    path = _safe(path, False)
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_BINARY', 0)
    with os.fdopen(_open(path, flags), 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > limit:
            raise SiteError('SITE_FILE_LIMIT')
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    if len(data) > limit or (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
        raise SiteError('SITE_CHANGED')
    return data


@contextmanager
def _parent(path):
    _safe(path.parent, True)
    if os.name != 'posix':
        yield None
        return
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(path.anchor, flags)
    try:
        for part in path.parent.parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            info = os.fstat(descriptor)
            if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
                raise SiteError('SITE_WRITABLE_ANCESTOR')
        yield descriptor
    finally:
        os.close(descriptor)


def _open(path, flags, mode=0o600):
    with _parent(path) as parent:
        if parent is None:
            descriptor = os.open(path, flags, mode)
            try:
                _safe(path, False)
            except BaseException:
                os.close(descriptor)
                raise
            return descriptor
        return os.open(path.name, flags | os.O_NOFOLLOW, mode, dir_fd=parent)


def _load_catalog():
    try:
        payload = _read(CATALOG_PATH.absolute(), MAX_CATALOG_BYTES)
    except FileNotFoundError as error:
        raise SiteError('SITE_CATALOG_MISSING') from error
    try:
        source = payload.decode('utf-8').replace('\r\n', '\n')
        prefix = 'CATALOG_JSON = '
        if not source.startswith(prefix) or not source.endswith('\n') or source.count('\n') != 1:
            raise SiteError('INVALID_SITE_CATALOG_DATA')
        literal = source[len(prefix):-1]
        expression = ast.parse(literal, mode='eval')
        if not isinstance(expression.body, ast.Constant) or type(expression.body.value) is not str:
            raise SiteError('INVALID_SITE_CATALOG_DATA')
        text = ast.literal_eval(expression.body)
        if repr(text) != literal:
            raise SiteError('INVALID_SITE_CATALOG_DATA')
        raw = text.encode('utf-8')
    except (UnicodeError, SyntaxError, RecursionError, TypeError) as error:
        raise SiteError('INVALID_SITE_CATALOG_DATA') from error
    if len(raw) > MAX_CATALOG_BYTES:
        raise SiteError('SITE_CATALOG_LIMIT')
    data = _json(raw)
    if not isinstance(data, dict) or set(data) != {'schema', 'sites'} or type(data['schema']) is not int or data['schema'] != 1:
        raise SiteError('INVALID_SITE_CATALOG')
    rows = data['sites']
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_TEMPLATES:
        raise SiteError('INVALID_SITE_CATALOG')
    result = {}
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {'id', 'title', 'description', 'files'} or
                not isinstance(row['id'], str) or not IDENTIFIER.fullmatch(row['id']) or row['id'] in result or
                any(not isinstance(row[key], str) or not row[key].strip() or len(row[key]) > maximum or
                    any(ord(char) < 32 for char in row[key]) for key, maximum in [('title', 100), ('description', 360)])):
            raise SiteError('INVALID_SITE_CATALOG')
        files = row['files']
        if not isinstance(files, dict) or not 3 <= len(files) <= MAX_SITE_FILES:
            raise SiteError('INVALID_SITE_FILES')
        folded = set()
        for name, content in files.items():
            _name(name)
            if name.casefold() in folded or not isinstance(content, str) or '\x00' in content or len(content.encode('utf-8')) > MAX_FILE_BYTES:
                raise SiteError('INVALID_SITE_FILES')
            if '{{DOMAIN}}' in content and not name.endswith('.html'):
                raise SiteError('SITE_DOMAIN_PLACEHOLDER_CONTEXT')
            folded.add(name.casefold())
        if ('index.html' not in files or '404.html' not in files or
                not {'about.html', 'about/index.html'}.intersection(files)):
            raise SiteError('SITE_REQUIRED_PAGES_MISSING')
        paths = set(files)
        if any(str(parent) in paths for name in paths for parent in PurePosixPath(name).parents if str(parent) != '.'):
            raise SiteError('SITE_PATH_COLLISION')
        result[row['id']] = row
    return result


def catalog():
    return [{key: row[key] for key in ('id', 'title', 'description')} for row in _load_catalog().values()]


def _render(row, domain):
    result = {name: content.replace('{{DOMAIN}}', html.escape(domain, quote=True)) if name.endswith('.html') else content
              for name, content in sorted(row['files'].items())}
    if any(len(value.encode('utf-8')) > MAX_FILE_BYTES for value in result.values()) or sum(len(value.encode('utf-8')) for value in result.values()) > MAX_CATALOG_BYTES:
        raise SiteError('SITE_RENDER_LIMIT')
    return result


def render_site(domain, template):
    domain = _domain(domain)
    rows = _load_catalog()
    if template not in rows:
        raise SiteError('UNKNOWN_SITE_TEMPLATE')
    return _render(rows[template], domain)


def _sync(path):
    if os.name == 'posix':
        with _parent(path) as parent:
            descriptor = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _write(path, data, mode=0o600):
    path = _safe(path, False)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_BINARY', 0)
    with os.fdopen(_open(path, flags, mode), 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def _encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')


def _atomic(path, value):
    _safe(path, False)
    temporary = path.with_name('.node-site-write-' + uuid.uuid4().hex)
    _write(temporary, _encoded(value))
    try:
        _safe(path, False)
        with _parent(path) as parent:
            if parent is None:
                os.replace(temporary, path)
            else:
                os.replace(temporary.name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        _sync(path.parent)
    finally:
        if temporary.exists():
            _unlink(temporary)


def _unlink(path):
    _safe(path, False)
    with _parent(path) as parent:
        if parent is None:
            path.unlink()
        else:
            os.unlink(path.name, dir_fd=parent)


def _tree(root):
    root = _safe(root, True)
    if not root.exists():
        return None
    records = []
    total = 0
    pending = [(root, 0)]
    while pending:
        folder, depth = pending.pop()
        _safe(folder, True)
        descriptor = None
        if os.name == 'posix':
            with _parent(folder) as parent:
                descriptor = os.open(folder.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            entries = os.scandir(descriptor if descriptor is not None else folder)
            with entries:
                for entry in entries:
                    if len(records) >= MAX_EXISTING_FILES or depth > MAX_EXISTING_DEPTH:
                        raise SiteError('SITE_TREE_LIMIT')
                    path = folder / entry.name
                    info = entry.stat(follow_symlinks=False)
                    relative = path.relative_to(root).as_posix()
                    if stat.S_ISDIR(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400:
                        _safe(path, True)
                        records.append(('directory', relative))
                        pending.append((path, depth + 1))
                    else:
                        _safe(path, False)
                        if info.st_size > MAX_EXISTING_BYTES - total:
                            raise SiteError('SITE_TREE_LIMIT')
                        total += info.st_size
                        digest = hashlib.sha256()
                        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_BINARY', 0)
                        with os.fdopen(_open(path, flags), 'rb') as stream:
                            before = os.fstat(stream.fileno())
                            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size != info.st_size or (info.st_ino and before.st_ino != info.st_ino):
                                raise SiteError('SITE_CHANGED')
                            remaining = before.st_size
                            while remaining:
                                block = stream.read(min(65536, remaining))
                                if not block:
                                    raise SiteError('SITE_CHANGED')
                                digest.update(block)
                                remaining -= len(block)
                            if stream.read(1):
                                raise SiteError('SITE_CHANGED')
                            after = os.fstat(stream.fileno())
                        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
                            raise SiteError('SITE_CHANGED')
                        records.append(('file', relative, before.st_size, digest.hexdigest()))
        finally:
            if descriptor is not None:
                os.close(descriptor)
    return hashlib.sha256(_encoded(sorted(records))).hexdigest()


def _state(path):
    if not path.exists() and not path.is_symlink():
        return None
    data = _json(_read(path, MAX_MANIFEST_BYTES))
    return _validate_state(data)


def _validate_state(data):
    if (not isinstance(data, dict) or set(data) != {'schema', 'kind', 'template', 'domain', 'files', 'tree'} or
            type(data['schema']) is not int or data['schema'] != 1 or data['kind'] != 'remnacust-node-site' or
            not isinstance(data['template'], str) or not IDENTIFIER.fullmatch(data['template']) or
            _domain(data['domain']) != data['domain'] or not isinstance(data['files'], dict) or
            not 3 <= len(data['files']) <= MAX_SITE_FILES or not isinstance(data['tree'], str) or not HEX.fullmatch(data['tree'])):
        raise SiteError('INVALID_SITE_STATE')
    for name, digest in data['files'].items():
        _name(name)
        if not isinstance(digest, str) or not HEX.fullmatch(digest):
            raise SiteError('INVALID_SITE_STATE')
    return data


@contextmanager
def _locked(deployment):
    path = _safe(deployment / LOCK_NAME, False)
    marker = b'remnacust-node-site-v1\n'
    try:
        _write(path, marker)
    except FileExistsError:
        try:
            if _read(path, len(marker)) != marker:
                raise SiteError('INVALID_SITE_LOCK')
        except PermissionError as error:
            raise SiteError('SITE_BUSY') from error
    descriptor = _open(path, os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0))
    try:
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise SiteError('SITE_BUSY') from error
        yield
    finally:
        os.close(descriptor)


def _exchange(left, right):
    if not sys.platform.startswith('linux'):
        return False
    library = ctypes.CDLL(None, use_errno=True)
    function = getattr(library, 'renameat2', None)
    if function is None:
        return False
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    with _parent(left) as left_parent, _parent(right) as right_parent:
        if function(left_parent, os.fsencode(left.name), right_parent, os.fsencode(right.name), 2) == 0:
            return True
    code = ctypes.get_errno()
    if code in {errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP}:
        return False
    raise OSError(code, os.strerror(code))


def _move(source, destination):
    _safe(source, True)
    _safe(destination, True)
    if destination.exists():
        raise SiteError('SITE_DESTINATION_EXISTS')
    if sys.platform.startswith('linux'):
        function = getattr(ctypes.CDLL(None, use_errno=True), 'renameat2', None)
        if function is None:
            raise SiteError('ATOMIC_SITE_RENAME_UNAVAILABLE')
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        with _parent(source) as source_parent, _parent(destination) as destination_parent:
            if function(source_parent, os.fsencode(source.name), destination_parent, os.fsencode(destination.name), 1) != 0:
                code = ctypes.get_errno()
                raise OSError(code, os.strerror(code))
    elif os.name == 'nt':
        os.rename(source, destination)
    else:
        raise SiteError('ATOMIC_SITE_RENAME_UNAVAILABLE')
    _sync(source.parent)
    if destination.parent != source.parent:
        _sync(destination.parent)


def _backup_root(deployment, value):
    result = _safe(Path(value) if value is not None else deployment.parent / 'backups' / 'node-sites', True)
    if result == deployment or result in deployment.parents or deployment in result.parents:
        raise SiteError('UNSAFE_SITE_BACKUP_ROOT')
    return result


def _owner(deployment):
    return hashlib.sha256(os.path.normcase(str(deployment)).encode('utf-8')).hexdigest()


def _raw_state(deployment):
    path = deployment / STATE_NAME
    return _read(path, MAX_MANIFEST_BYTES) if path.exists() or path.is_symlink() else None


def _receipt(deployment, archive):
    data = _json(_read(archive / RECEIPT_NAME, MAX_MANIFEST_BYTES))
    if (not isinstance(data, dict) or set(data) != {'schema', 'kind', 'deployment', 'tree', 'state'} or
            type(data['schema']) is not int or data['schema'] != 1 or data['kind'] != 'remnacust-node-site-backup' or
            data['deployment'] != _owner(deployment) or
            any(not isinstance(value, str) or not HEX.fullmatch(value) for value in [data['tree']]) or
            (data['state'] is not None and (not isinstance(data['state'], str) or not HEX.fullmatch(data['state'])))):
        raise SiteError('INVALID_SITE_BACKUP')
    _safe(archive / STATE_NAME, False)
    raw = _read(archive / STATE_NAME, MAX_MANIFEST_BYTES) if (archive / STATE_NAME).exists() else None
    if (hashlib.sha256(raw).hexdigest() if raw is not None else None) != data['state']:
        raise SiteError('SITE_BACKUP_CHANGED')
    if raw is not None:
        _validate_state(_json(raw))
    return data


def _prepare(deployment, backup_root, token, old, new, state, source=None):
    raw = _raw_state(deployment)
    if old is not None:
        _mkdir(backup_root)
        if deployment.stat().st_dev != backup_root.stat().st_dev:
            raise SiteError('SITE_BACKUP_FILESYSTEM')
        archive = backup_root / ('node-site-' + token)
        _make_directory(archive, 0o700)
        if raw is not None:
            _write(archive / STATE_NAME, raw)
        _write(archive / RECEIPT_NAME, _encoded({'schema': 1, 'kind': 'remnacust-node-site-backup',
                'deployment': _owner(deployment), 'tree': old,
                'state': hashlib.sha256(raw).hexdigest() if raw is not None else None}))
        _sync(archive)
    if _tree(deployment / 'www') != old or _raw_state(deployment) != raw:
        raise SiteError('SITE_CHANGED')
    data = {'schema': 1, 'token': token, 'backupRoot': str(backup_root), 'old': old, 'new': new,
            'oldState': hashlib.sha256(raw).hexdigest() if raw is not None else None,
            'state': state, 'source': source}
    if len(_encoded(data)) > MAX_MANIFEST_BYTES * 2:
        raise SiteError('SITE_MANIFEST_LIMIT')
    _atomic(deployment / JOURNAL_NAME, data)
    try:
        return _finish(deployment, backup_root)
    except OSError:
        website = deployment / 'www'
        stage = deployment / ('.node-site-stage-' + token)
        previous = backup_root / ('node-site-' + token) / 'www'
        try:
            if old is not None and _tree(website) is None and _tree(previous) == old:
                _move(previous, website)
            elif old is not None and _tree(website) == new and _tree(stage) == old:
                _exchange(website, stage)
                _sync(deployment)
        except (OSError, SiteError):
            pass
        raise


def _finish(deployment, backup_root):
    journal = deployment / JOURNAL_NAME
    if not journal.exists() and not journal.is_symlink():
        return None
    data = _json(_read(journal, MAX_MANIFEST_BYTES * 2))
    if (not isinstance(data, dict) or set(data) != {'schema', 'token', 'backupRoot', 'old', 'new', 'oldState', 'state', 'source'} or
            type(data['schema']) is not int or data['schema'] != 1 or
            not isinstance(data['token'], str) or not TOKEN.fullmatch(data['token']) or
            data['backupRoot'] != str(backup_root) or
            any(value is not None and (not isinstance(value, str) or not HEX.fullmatch(value))
                for value in [data['old'], data['oldState']]) or
            not isinstance(data['new'], str) or not HEX.fullmatch(data['new']) or
            (data['source'] is not None and (not isinstance(data['source'], str) or
                not re.fullmatch(r'node-site-[a-f0-9]{32}', data['source'])))):
        raise SiteError('INVALID_SITE_TRANSACTION')
    state = _validate_state(data['state']) if data['state'] is not None else None
    validation = deployment / ('.node-site-stage-' + data['token'])
    archive = backup_root / ('node-site-' + data['token'])
    previous = archive / 'www'
    website = deployment / 'www'
    expected = data['new']
    if state is not None and state['tree'] != expected:
        raise SiteError('INVALID_SITE_TRANSACTION')
    state_path = deployment / STATE_NAME
    raw = _raw_state(deployment)
    current = hashlib.sha256(raw).hexdigest() if raw is not None else None
    live, stage = _tree(website), _tree(validation)
    desired = _encoded(state) if state is not None else None
    if current != data['oldState'] and not (live == expected and raw == desired):
        raise SiteError('SITE_STATE_CHANGED')
    old = data['old']
    if old is not None and _receipt(deployment, archive)['tree'] != old:
        raise SiteError('INVALID_SITE_BACKUP')
    archived = _tree(previous)
    if data['source'] is not None:
        origin = backup_root / data['source']
        if _receipt(deployment, origin)['tree'] != expected:
            raise SiteError('SITE_BACKUP_CHANGED')
        if stage is None and live == old and archived is None:
            if _tree(origin / 'www') != expected:
                raise SiteError('SITE_BACKUP_CHANGED')
            _move(origin / 'www', validation)
            stage = _tree(validation)
    if live == old and stage == expected and archived is None:
        if old is None:
            _move(validation, website)
        elif _exchange(website, validation):
            _sync(deployment)
        else:
            _move(website, previous)
            _move(validation, website)
        live, stage, archived = _tree(website), _tree(validation), _tree(previous)
    elif live is None and stage == expected and archived == old and old is not None:
        _move(validation, website)
        live, stage = _tree(website), None
    if live != expected:
        raise SiteError('SITE_RECOVERY_CONFLICT')
    if old is not None and stage == old and archived is None:
        _move(validation, previous)
        stage, archived = None, _tree(previous)
    if stage is not None or archived != old:
        raise SiteError('SITE_RECOVERY_CONFLICT')
    raw = _raw_state(deployment)
    current = hashlib.sha256(raw).hexdigest() if raw is not None else None
    if raw != desired:
        if current != data['oldState']:
            raise SiteError('SITE_STATE_CHANGED')
        if state is None:
            _unlink(state_path)
        else:
            _atomic(state_path, state)
    if state is not None:
        _state(state_path)
    _unlink(journal)
    _sync(deployment)
    return {'backup': str(archive) if old is not None else None, 'generation': expected,
            'template': state['template'] if state is not None else None}


def _initial_site(website):
    if not website.exists():
        return True
    descriptor = None
    if os.name == 'posix':
        with _parent(website) as parent:
            descriptor = os.open(website.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        with os.scandir(descriptor if descriptor is not None else _safe(website, True)) as entries:
            first = next(entries, None)
            if first is None:
                return True
            if first.name != 'index.html' or next(entries, None) is not None:
                return False
            info = first.stat(follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400 or info.st_nlink > 1 or info.st_size != len(OLD_STUB):
                return False
        try:
            _safe(website / 'index.html', False)
        except SiteError:
            _safe(website, True)
            return False
        try:
            return _read(website / 'index.html', len(OLD_STUB)) == OLD_STUB
        except (SiteError, FileNotFoundError):
            _safe(website, True)
            return False
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _preserved(deployment):
    try:
        state = _state(deployment / STATE_NAME)
    except (SiteError, OSError):
        state = None
    return {'status': 'preserved', 'changed': False, 'directory': str(deployment / 'www'),
            'template': state['template'] if state is not None else None, 'generation': None, 'backup': None}


def install_site(deployment, domain, template='random', replace=False, backup_root=None):
    domain = _domain(domain)
    if type(replace) is not bool or not isinstance(template, str) or (template != 'random' and not IDENTIFIER.fullmatch(template)):
        raise SiteError('INVALID_SITE_REQUEST')
    deployment = _safe(Path(deployment), True)
    website = _safe(deployment / 'www', True)
    journal = deployment / JOURNAL_NAME
    pending = journal.exists() or journal.is_symlink()
    if not replace and not pending and website.exists() and not _initial_site(website):
        return _preserved(deployment)
    backup_root = _backup_root(deployment, backup_root)
    if replace:
        _tree(website)
    _mkdir(deployment)
    with _locked(deployment):
        recovered = _finish(deployment, backup_root)
        if recovered is not None and not replace:
            return {'status': 'preserved', 'changed': True, 'directory': str(website),
                    'template': recovered['template'], 'generation': recovered['generation'], 'backup': recovered['backup']}
        if not replace and website.exists() and not _initial_site(website):
            return _preserved(deployment)
        state_path = deployment / STATE_NAME
        state = _state(state_path)
        if not replace and state is not None and website.exists():
            return _preserved(deployment)
        old = _tree(website)
        initial_trees = {
            hashlib.sha256(_encoded([])).hexdigest(),
            hashlib.sha256(_encoded([('file', 'index.html', len(OLD_STUB), hashlib.sha256(OLD_STUB).hexdigest())])).hexdigest(),
        }
        if not replace and old is not None and old not in initial_trees:
            return _preserved(deployment)
        rows = _load_catalog()
        choices = [identifier for identifier in rows if not (replace and state is not None and len(rows) > 1 and identifier == state['template'])]
        selected = (state['template'] if state is not None and not replace else secrets.choice(choices)) if template == 'random' else template
        if selected not in rows:
            raise SiteError('UNKNOWN_SITE_TEMPLATE')
        files = _render(rows[selected], domain)
        token = uuid.uuid4().hex
        stage = _safe(deployment / ('.node-site-stage-' + token), True)
        _make_directory(stage, 0o755)
        for name, content in files.items():
            target = stage / name
            _mkdir(target.parent)
            _write(target, content.encode('utf-8'), mode=0o644)
        for folder in sorted({stage, *(path.parent for path in stage.rglob('*'))}, key=lambda path: len(path.parts), reverse=True):
            _sync(folder)
        new_state = {'schema': 1, 'kind': 'remnacust-node-site', 'template': selected, 'domain': domain,
                     'files': {name: hashlib.sha256(content.encode('utf-8')).hexdigest() for name, content in files.items()},
                     'tree': _tree(stage)}
        if len(_encoded(new_state)) > MAX_MANIFEST_BYTES:
            raise SiteError('SITE_MANIFEST_LIMIT')
        if _tree(website) != old:
            raise SiteError('SITE_CHANGED')
        archived = _prepare(deployment, backup_root, token, old, new_state['tree'], new_state)
        return {'status': 'replaced' if replace and old is not None else 'installed', 'changed': True,
                'directory': str(website), 'template': selected, 'generation': new_state['tree'], 'backup': archived['backup']}


def restore_site(deployment, backup, expected_generation, backup_root=None):
    if not isinstance(expected_generation, str) or not HEX.fullmatch(expected_generation):
        raise SiteError('INVALID_SITE_GENERATION')
    deployment = _safe(Path(deployment), True)
    website = _safe(deployment / 'www', True)
    backup_root = _backup_root(deployment, backup_root)
    archive = _safe(Path(backup), True)
    if archive.parent != backup_root or not re.fullmatch(r'node-site-[a-f0-9]{32}', archive.name):
        raise SiteError('UNSAFE_SITE_BACKUP')
    with _locked(deployment):
        if (deployment / JOURNAL_NAME).exists() or (deployment / JOURNAL_NAME).is_symlink():
            raise SiteError('SITE_TRANSACTION_PENDING')
        current = _tree(website)
        state = _state(deployment / STATE_NAME)
        if current != expected_generation or (state is not None and state['tree'] != current):
            raise SiteError('SITE_GENERATION_CHANGED')
        receipt = _receipt(deployment, archive)
        previous = _tree(archive / 'www')
        if previous is None or previous != receipt['tree']:
            raise SiteError('SITE_BACKUP_CHANGED')
        restored_state = _state(archive / STATE_NAME) if receipt['state'] is not None else None
        if restored_state is not None and restored_state['tree'] != previous:
            restored_state = None
        token = uuid.uuid4().hex
        result = _prepare(deployment, backup_root, token, current, previous, restored_state, source=archive.name)
        return {'status': 'restored', 'changed': True, 'directory': str(website),
                'template': restored_state['template'] if restored_state else None,
                'generation': previous, 'backup': result['backup']}


def main(argv=None):
    parser = argparse.ArgumentParser(description='Install bundled local node websites without changing listeners.')
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--domain')
    parser.add_argument('--template', default='random')
    parser.add_argument('--backup-root', type=Path)
    parser.add_argument('--replace', action='store_true')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--restore', type=Path)
    parser.add_argument('--expected-generation')
    args = parser.parse_args(argv)
    try:
        if args.list:
            result = catalog()
        elif args.restore:
            if args.directory is None or args.expected_generation is None or args.replace or args.domain is not None:
                parser.error('--restore requires --directory and --expected-generation, without --replace or --domain')
            result = restore_site(args.directory, args.restore, args.expected_generation, args.backup_root)
        else:
            if args.directory is None or args.domain is None:
                parser.error('--directory and --domain are required unless --list is used')
            result = install_site(args.directory, args.domain, args.template, args.replace, args.backup_root)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (SiteError, OSError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


try:
    TEMPLATES = [row['id'] for row in catalog()]
except SiteError:
    TEMPLATES = []


if __name__ == '__main__':
    sys.exit(main())
