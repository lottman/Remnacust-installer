#!/usr/bin/env python3
"""Own only the node guard table; keep SSH and outbound reply traffic available."""
import argparse
from contextlib import contextmanager
import errno
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import tempfile

TABLE = 'remnacust_node_guard'
ROOT = Path('/etc/remnacust-node-firewall')
UNIT = Path('/etc/systemd/system/remnacust-node-firewall.service')
CONTROL_PROFILE = Path('/etc/ufw/applications.d/remnacust-node-control')
SITE_PROFILE = Path('/etc/ufw/applications.d/remnacust-node-site')
MAX_FILE_BYTES = 1024 * 1024
MAX_FILES = 256
UNIT_TEXT = '''[Unit]
Description=Remnacust node source guard
After=network-pre.target docker.service
Before=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /etc/remnacust-node-firewall/guard.py restore
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
'''
SITE_PREFIX = '[Remnacust Node HTTPS]\ntitle=Node HTTPS website\ndescription=Managed node website\nports='


def run(*args, check=True, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True,
                          check=check, timeout=30)


def network(value):
    result = ipaddress.ip_network(value, strict=False)
    if result.prefixlen == 0 or result.is_multicast or result.is_unspecified:
        raise ValueError('A specific panel IP or subnet is required')
    return str(result)


def render(panel, ssh_ports, bridges, https_port=0):
    panel = network(panel)
    ports = sorted(set(ssh_ports) | {22})
    if len(ports) > 64 or any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
        raise ValueError('Invalid SSH ports')
    if len(bridges) > 128 or any(not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', b) for b in bridges):
        raise ValueError('Invalid Docker bridge')
    family = 'ip6' if ':' in panel else 'ip'
    source = f'{family} saddr {panel} accept'
    trusted = ('iifname { ' + ', '.join(json.dumps(b) for b in sorted(set(bridges))) + ' } accept') if bridges else ''
    if type(https_port) is not int or not 0 <= https_port <= 65535:
        raise ValueError('Invalid HTTPS port')
    website = f'tcp dport {https_port} accept' if https_port else ''
    return f'''table inet {TABLE} {{
 set acme_http {{ type inet_service; flags timeout; }}
 chain input {{
  type filter hook input priority -10; policy accept;
  iifname "lo" accept
  ct state invalid drop
  {source}
  tcp dport {{ {', '.join(map(str, ports))} }} accept
  tcp dport @acme_http accept
  {website}
  ct state established,related ct direction reply accept
  meta l4proto ipv6-icmp icmpv6 type {{ nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert }} ip6 hoplimit 255 accept
  meta l4proto ipv6-icmp icmpv6 type {{ destination-unreachable, packet-too-big, time-exceeded, parameter-problem }} accept
  drop
 }}
 chain forward {{
  type filter hook forward priority -10; policy accept;
  ct state invalid drop
  {source}
  ct state established,related ct direction reply accept
  {trusted}
  drop
 }}
}}
'''


def discover():
    ports = {22}
    connection = os.environ.get('SSH_CONNECTION', '').split()
    if len(connection) == 4 and connection[-1].isdigit():
        ports.add(int(connection[-1]))
    try:
        for line in run('/usr/sbin/sshd', '-T').stdout.splitlines():
            if re.fullmatch(r'port \d+', line):
                ports.add(int(line.split()[1]))
    except (OSError, subprocess.SubprocessError):
        pass
    bridges = []
    ids = run('docker', 'network', 'ls', '--filter', 'driver=bridge', '-q').stdout.split()
    if ids:
        for item in json.loads(run('docker', 'network', 'inspect', *ids).stdout):
            options = item.get('Options') or {}
            bridges.append(options.get('com.docker.network.bridge.name') or
                           ('docker0' if item['Name'] == 'bridge' else 'br-' + item['Id'][:12]))
    return sorted(ports), bridges


def replace_table(rules):
    existing = run('nft', 'list', 'table', 'inet', TABLE, check=False)
    if existing.returncode and run('nft', 'list', 'tables', check=False).returncode:
        raise RuntimeError('Cannot inspect nftables')
    transaction = (f'delete table inet {TABLE}\n' if existing.returncode == 0 else '') + rules
    run('nft', '-c', '-f', '-', data=transaction)
    run('nft', '-f', '-', data=transaction)


def acme_window(open_window):
    # A timed nftables element closes even if Certbot or the host process crashes.
    if run('nft', 'list', 'table', 'inet', TABLE, check=False).returncode:
        if run('nft', 'list', 'tables', check=False).returncode:
            raise RuntimeError('Cannot inspect nftables')
        return  # No owned guard is installed; external firewalls still apply.
    if run('nft', 'list', 'set', 'inet', TABLE, 'acme_http', check=False).returncode:
        if not open_window:
            return
        # Upgrade an older guard in place, without replacing its rules or state.
        run('nft', '-f', '-', data=(
            f'add set inet {TABLE} acme_http {{ type inet_service; flags timeout; }}\n'
            f'insert rule inet {TABLE} input tcp dport @acme_http accept\n'
        ))
    run('nft', 'delete', 'element', 'inet', TABLE, 'acme_http', '{', '80', '}', check=False)
    if open_window:
        run('nft', 'add', 'element', 'inet', TABLE, 'acme_http', '{', '80', 'timeout', '15m', '}')


def write(path, value, mode=0o600):
    if path.is_symlink():
        raise ValueError('Refusing a symlink')
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.guard-')
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(value)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def site_access(https_port, profile=Path('/etc/ufw/applications.d/remnacust-node-site')):
    if type(https_port) is not int or not 0 <= https_port <= 65535:
        raise ValueError('Invalid HTTPS port')
    ufw = shutil.which('ufw')
    if not ufw:
        return
    if profile.is_symlink() or profile.parent.is_symlink() or not profile.parent.is_dir() or profile.parent.stat().st_uid != os.geteuid() or profile.parent.stat().st_mode & 0o022:
        raise ValueError('Unsafe UFW application profile')
    if profile.exists():
        metadata = profile.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
            raise ValueError('Unsafe UFW application profile')
    prefix = '[Remnacust Node HTTPS]\ntitle=Node HTTPS website\ndescription=Managed node website\nports='
    before = profile.read_text() if profile.exists() and profile.stat().st_size <= 512 else None
    if profile.exists() and (before is None or not re.fullmatch(re.escape(prefix) + r'[0-9]{1,5}/tcp\n', before)):
        raise ValueError('UFW profile has unmanaged changes')
    try:
        if https_port:
            write(profile, prefix + str(https_port) + '/tcp\n')
            run(ufw, 'app', 'update', 'Remnacust Node HTTPS')
            run(ufw, 'allow', 'Remnacust Node HTTPS')
        elif before is not None:
            run(ufw, '--force', 'delete', 'allow', 'Remnacust Node HTTPS')
            profile.unlink()
    except BaseException:
        if before is None:
            if profile.exists():
                run(ufw, '--force', 'delete', 'allow', 'Remnacust Node HTTPS')
                profile.unlink()
        else:
            write(profile, before)
            run(ufw, 'app', 'update', 'Remnacust Node HTTPS')
        raise


def control_access(panel, ports, profile=Path('/etc/ufw/applications.d/remnacust-node-control'), remove=False):
    ufw = shutil.which('ufw')
    if not ufw:
        return lambda: None
    panel = network(panel)
    ports = sorted(set(ports))
    if not 1 <= len(ports) <= 2 or any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
        raise ValueError('Invalid node control ports')
    if profile.is_symlink() or profile.parent.is_symlink() or not profile.parent.is_dir() or profile.parent.stat().st_uid != os.geteuid() or profile.parent.stat().st_mode & 0o022:
        raise ValueError('Unsafe UFW control profile')
    before = None
    old_panel = None
    if profile.exists():
        metadata = profile.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022 or metadata.st_size > 512:
            raise ValueError('Unsafe UFW control profile')
        before = profile.read_text()
        match = re.fullmatch(r'\[Remnacust Node Control\]\ntitle=Node control\ndescription=Panel source ([0-9a-fA-F.:/]+)\nports=([0-9]{1,5}(?:,[0-9]{1,5})?)/tcp\n', before)
        if not match:
            raise ValueError('UFW control profile has unmanaged changes')
        old_panel = network(match[1])
        if remove and (old_panel != panel or sorted(map(int, match[2].split(','))) != ports):
            raise ValueError('UFW control profile belongs to another installation')
    app = 'Remnacust Node Control'
    def rule(source, remove=False):
        run(ufw, *(['--force', 'delete'] if remove else []), 'allow', 'from', source, 'to', 'any', 'app', app)
    def restore():
        if profile.exists():
            rule(panel, remove=True)
        if before is None:
            profile.unlink(missing_ok=True)
        else:
            write(profile, before)
            run(ufw, 'app', 'update', app)
            rule(old_panel)
    try:
        if remove:
            if before is not None:
                rule(old_panel, remove=True)
                profile.unlink()
            return restore
        if old_panel and old_panel != panel:
            rule(old_panel, remove=True)
        write(profile, f'[{app}]\ntitle=Node control\ndescription=Panel source {panel}\nports=' + ','.join(map(str, ports)) + '/tcp\n')
        run(ufw, 'app', 'update', app)
        rule(panel)
    except BaseException:
        restore()
        raise
    return restore


def cleanup_path(path, directory=False):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError(f'Unsafe cleanup path: {path}')
    for candidate in [*reversed(path.parents), path]:
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f'Unsafe cleanup symlink: {candidate}')
        is_directory = candidate != path or directory
        if (info.st_uid != 0 or
                (info.st_mode & 0o022 and not (candidate != path and is_directory and info.st_mode & stat.S_ISVTX)) or
                (is_directory and not stat.S_ISDIR(info.st_mode)) or
                (not is_directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE_BYTES))):
            raise ValueError(f'Unsafe cleanup file or directory: {candidate}')
    return path


def cleanup_read(path, limit=MAX_FILE_BYTES):
    path = cleanup_path(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, 'rb') as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError(f'Unsafe cleanup file: {path}')
        data = file.read(limit + 1)
        if len(data) > limit:
            raise ValueError(f'Cleanup file too large: {path}')
    return data.decode('utf-8')


def cleanup_children(path):
    cleanup_path(path, directory=True)
    if not path.exists():
        return []
    children = []
    with os.scandir(path) as entries:
        for entry in entries:
            if len(children) >= MAX_FILES:
                raise ValueError(f'Too many cleanup files: {path}')
            child = Path(entry.path)
            cleanup_path(child, directory=entry.is_dir(follow_symlinks=False))
            children.append(child)
    return children


def cleanup_port(value):
    if type(value) is not int or not 0 <= value <= 65535:
        raise ValueError('Invalid cleanup port')
    return value


def cleanup_state():
    cleanup_path(ROOT, directory=True)
    data = cleanup_read(ROOT / 'state.json', 16384)
    if data is None:
        return None
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate guard state field')
            result[key] = value
        return result
    state = json.loads(data, object_pairs_hook=pairs)
    if not isinstance(state, dict):
        raise ValueError('Invalid guard state')
    return state


def owned_panel(owner_root):
    if not owner_root:
        raise ValueError('Panel lookup requires --owner-root')
    owner = str(cleanup_path(Path(owner_root).absolute(), directory=True).resolve())
    state = cleanup_state()
    if state is None or state.get('ownerRoot') != owner:
        return ''
    return network(state['panel'])


def detach_renewal(owner_root, project):
    if not owner_root:
        raise ValueError('Renewal detach requires --owner-root')
    if not isinstance(project, str) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', project):
        raise ValueError('Invalid renewal project')
    owner = cleanup_path(Path(owner_root).absolute(), directory=True).resolve()
    acme = owner / 'acme' / project
    script = acme / 'renew.sh'
    try:
        before = cleanup_read(script, 16384)
    except UnicodeError:
        print('Renewal script preserved: unmanaged content')
        return
    if before is None:
        return
    lines = before.splitlines(keepends=True)
    preserved = 'Renewal script preserved: unmanaged content'
    if (len(lines) != 3 or lines[:2] != ['#!/usr/bin/env bash\n', 'set -eu\n'] or
            not lines[2].startswith('exec ') or not lines[2].endswith('\n')):
        print(preserved)
        return
    command = lines[2][5:-1]
    try:
        tokens = shlex.split(command)
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|<>()')
        lexer.whitespace_split = True
        lexer.commenters = ''
        if (list(lexer) != tokens or any(re.fullmatch(r'[;&|<>()]+', token) or
                                       token.startswith('#') or '$' in token or '`' in token or
                                       any(ord(character) < 32 for character in token) for token in tokens)):
            print(preserved)
            return
    except ValueError:
        print(preserved)
        return
    certbot = str(owner / 'tools/certbot/bin/certbot')
    if tokens[:2] == [certbot, 'renew']:
        return
    prefix = ['/usr/bin/python3', '-I', str(acme / 'ufw_guard.py'), '--root', str(owner), '--', certbot, 'renew']
    if tokens[:len(prefix)] != prefix:
        print(preserved)
        return
    hooks = {'--pre-hook': str(acme / 'acme-open.sh'), '--post-hook': str(acme / 'acme-close.sh')}
    remaining = [certbot, 'renew']
    index = len(prefix)
    while index < len(tokens):
        if tokens[index] in hooks and index + 1 < len(tokens) and tokens[index + 1] == hooks[tokens[index]]:
            index += 2
        else:
            remaining.append(tokens[index])
            index += 1
    if cleanup_read(script, 16384) != before:
        raise RuntimeError('Renewal script changed during detach')
    write(script, '#!/usr/bin/env bash\nset -eu\nexec ' + shlex.join(remaining) + '\n', 0o700)
    print('Owned renewal script detached from firewall wrapper and managed hooks')


def cleanup_owner(state, owner_root, api_port):
    owner = str(cleanup_path(Path(owner_root).absolute(), directory=True).resolve())
    tracked_owner = state.get('ownerRoot')
    if tracked_owner is not None:
        if tracked_owner != owner:
            return False, 'Guard preserved: ownerRoot mismatch'
    elif owner != '/opt/remnacust':
        return False, 'Legacy guard preserved: ownerless state requires /opt/remnacust'
    if api_port is None and tracked_owner is None:
        return False, 'Legacy guard preserved: ownerless state requires an explicit API port'
    if 'controlPorts' in state:
        ports = state['controlPorts']
        if not isinstance(ports, list) or len(ports) > 2 or any(cleanup_port(p) == 0 for p in ports) or len(set(ports)) != len(ports):
            raise ValueError('Invalid tracked controlPorts')
        if api_port is not None and ((ports and api_port not in ports) or (not ports and api_port != 0)):
            return False, 'Guard preserved: API port does not match tracked controlPorts'
        if api_port is None:
            return True, 'Owned guard cleanup: exact ownerRoot match; API port omitted'
        return True, ('Owned guard cleanup' if tracked_owner is not None else
                      'Legacy guard cleanup: default owner and tracked API match')
    if tracked_owner is not None:
        if api_port is None:
            return True, 'Owned guard cleanup: exact ownerRoot match; API port omitted'
        return False, 'Guard preserved: controlPorts missing from owner-scoped state'
    return True, 'Legacy guard cleanup: /opt/remnacust only; old state has no controlPorts'


def cleanup_profiles(state, https_port):
    removals = []
    reports = []
    site = cleanup_read(SITE_PROFILE, 512)
    expected = cleanup_port(state.get('httpsPort', 0)) if state is not None else https_port
    if site is not None:
        if expected and site == SITE_PREFIX + str(expected) + '/tcp\n':
            removals.append((SITE_PROFILE, ('allow', 'Remnacust Node HTTPS')))
        else:
            reports.append('HTTPS profile preserved: expected managed port/content did not match')
    if state is not None:
        control = cleanup_read(CONTROL_PROFILE, 512)
        if control is not None:
            ports = state.get('controlPorts', [])
            panel = network(state['panel'])
            expected_control = ('[Remnacust Node Control]\ntitle=Node control\n'
                                f'description=Panel source {panel}\nports=' +
                                ','.join(map(str, sorted(ports))) + '/tcp\n')
            if ports and control == expected_control:
                removals.append((CONTROL_PROFILE, ('allow', 'from', panel, 'to', 'any', 'app', 'Remnacust Node Control')))
            else:
                reports.append('Control profile preserved: tracked source/ports/content did not match')
    return removals, reports


def cleanup_plan(state, https_port):
    profiles, reports = cleanup_profiles(state, https_port)
    files = []
    if state is None:
        return files, profiles, reports
    cleanup_children(ROOT)
    dropins = UNIT.with_name(UNIT.name + '.d')
    for path in cleanup_children(dropins):
        match = re.fullmatch(r'relay-([0-9a-fA-F.:-]+)\.conf', path.name)
        if not match or path.is_dir():
            continue
        ip = match[1]
        try:
            address = ipaddress.ip_address(ip.replace('-', '.') if '-' in ip else ip)
        except ValueError:
            continue
        if '-' in ip and (address.version != 4 or ip != str(address).replace('.', '-')):
            continue
        relay = ROOT / f'relay-{ip}.nft'
        content = cleanup_read(relay, 4096)
        expected = f'[Service]\nExecStartPost=/usr/sbin/nft -f /etc/remnacust-node-firewall/relay-{ip}.nft\n'
        family = 'ip6' if address.version == 6 else 'ip'
        rule = (rf'insert rule inet {TABLE} (?:input|forward) {family} saddr {re.escape(ip)} '
                rf'tcp dport 443 accept comment "rc-cascade-{re.escape(ip)}-443"\n')
        paired_variant = (f'insert rule inet {TABLE} input ip saddr {address} tcp dport 443 '
                          f'ct state != invalid counter accept comment "rc-cascade-{ip}-443"\n')
        known_content = ('-' not in ip and content is not None and re.fullmatch('(?:' + rule + '){1,2}', content))
        known_variant = address.version == 4 and ip == str(address).replace('.', '-') and content == paired_variant
        if known_variant:
            known_content = True
        if cleanup_read(path, 4096) == expected and known_content:
            files.extend([path, relay])
            if known_variant:
                reports.append(f'Unmarked UFW relay allow for {address}:443 preserved: ownership cannot be verified')
        else:
            reports.append(f'Relay files preserved: unmanaged content for {ip}')
    unit = cleanup_read(UNIT, 16384)
    if unit == UNIT_TEXT:
        files.append(UNIT)
    elif unit is not None:
        reports.append('Unit file preserved: unmanaged content')
    helper = cleanup_read(ROOT / 'guard.py')
    if helper is not None:
        if (helper.startswith('#!/usr/bin/env python3\n"""Own only the node guard table; keep SSH and outbound reply traffic available."""\n') and
                "TABLE = 'remnacust_node_guard'\n" in helper and
                "ROOT = Path('/etc/remnacust-node-firewall')\n" in helper):
            files.append(ROOT / 'guard.py')
        else:
            reports.append('Helper preserved: unmanaged content')
    files.append(ROOT / 'state.json')
    return files, profiles, reports


@contextmanager
def cleanup_lock():
    import fcntl
    lock_path = ROOT / 'lock'
    cleanup_path(lock_path)
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or info.st_nlink != 1 or info.st_size > MAX_FILE_BYTES:
            raise ValueError(f'Unsafe cleanup lock: {lock_path}')
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def cleanup_profiles_remove(profiles):
    if not profiles:
        return
    ufw = shutil.which('ufw')
    if not ufw:
        raise RuntimeError('Cannot remove managed UFW profiles: ufw is unavailable')
    for path, rule in profiles:
        run(ufw, '--force', 'delete', *rule)
        path.unlink()


def uninstall(owner_root, api_port=None, https_port=0):
    if not owner_root:
        raise ValueError('Cleanup requires --owner-root')
    cleanup_path(Path(owner_root).absolute(), directory=True)
    if api_port is not None:
        cleanup_port(api_port)
    cleanup_port(https_port)
    state = cleanup_state()
    if state is None:
        if api_port is None:
            print('No guard state: exact ownerRoot cannot be verified; cleanup skipped')
            return
        _, profiles, reports = cleanup_plan(None, https_port)
        cleanup_profiles_remove(profiles)
        print('; '.join(['No guard state: owned guard cleanup skipped', *reports]))
        return
    owned, report = cleanup_owner(state, owner_root, api_port)
    if not owned:
        print(report)
        return
    cleanup_plan(state, https_port)
    with cleanup_lock():
        state = cleanup_state()
        if state is None:
            print('No guard state: owned guard cleanup skipped')
            return
        owned, report = cleanup_owner(state, owner_root, api_port)
        if not owned:
            print(report)
            return
        files, profiles, reports = cleanup_plan(state, https_port)
        if profiles and not shutil.which('ufw'):
            raise RuntimeError('Cannot remove managed UFW profiles: ufw is unavailable')
        if UNIT.exists():
            run('systemctl', 'disable', '--now', 'remnacust-node-firewall.service')
        replace_table('')
        cleanup_profiles_remove(profiles)
        for path in dict.fromkeys(files):
            path.unlink(missing_ok=True)
        run('systemctl', 'daemon-reload')
        for directory in (UNIT.with_name(UNIT.name + '.d'),):
            try:
                directory.rmdir()
            except OSError as error:
                if error.errno not in (errno.ENOENT, errno.ENOTEMPTY, errno.EEXIST):
                    raise
        print('; '.join([report, 'Owned guard removed; other firewall rules were not changed', *reports]))


def apply(panel, https_port=0, control_ports=None, owner_root=None):
    panel = network(panel)
    if ROOT.is_symlink() or (ROOT.exists() and
                            (ROOT.stat().st_uid != 0 or ROOT.stat().st_mode & 0o022)):
        raise ValueError('Unsafe guard directory')
    ROOT.mkdir(mode=0o700, exist_ok=True)
    previous_state = json.loads((ROOT / 'state.json').read_text()) if (ROOT / 'state.json').exists() else {}
    control_ports = previous_state.get('controlPorts', []) if control_ports is None else control_ports
    owner_root = previous_state.get('ownerRoot', '') if owner_root is None else str(Path(owner_root).resolve())
    ports, bridges = discover()
    rules = render(panel, ports, bridges, https_port)
    previous = run('nft', 'list', 'table', 'inet', TABLE, check=False)
    paths = [ROOT / 'guard.py', ROOT / 'state.json', UNIT]
    for path in paths:
        if path.is_symlink():
            raise ValueError('Unsafe guard file')
    old = {path: path.read_text() if path.exists() else None for path in paths}
    restore_control = lambda: None
    try:
        if control_ports:
            restore_control = control_access(panel, control_ports)
        write(ROOT / 'guard.py', Path(__file__).read_text())
        write(ROOT / 'state.json', json.dumps({'panel': panel, 'sshPorts': ports, 'httpsPort': https_port, 'controlPorts': control_ports, 'ownerRoot': owner_root}))
        write(UNIT, UNIT_TEXT)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', 'remnacust-node-firewall.service')
        replace_table(rules)
    except Exception:
        try:
            restore_control()
        finally:
            for path, content in old.items():
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    write(path, content)
            replace_table(previous.stdout if previous.returncode == 0 else '')
            if old[UNIT] is None:
                run('systemctl', 'disable', 'remnacust-node-firewall.service', check=False)
            run('systemctl', 'daemon-reload', check=False)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['apply', 'restore', 'remove', 'uninstall', 'owned-panel', 'detach-renewal', 'render', 'acme-open', 'acme-close', 'site', 'remove-control'])
    parser.add_argument('--panel')
    parser.add_argument('--https-port', type=int, default=0)
    parser.add_argument('--api-port', type=int); parser.add_argument('--inbound-port', type=int)
    parser.add_argument('--owner-root')
    parser.add_argument('--project')
    args = parser.parse_args()
    if args.action == 'render':
        print(render(args.panel, [22], [], args.https_port))
        return
    if os.geteuid() != 0:
        raise SystemExit('Root is required')
    if args.action == 'owned-panel':
        panel = owned_panel(args.owner_root)
        if panel:
            print(panel)
        return
    if args.action == 'detach-renewal':
        detach_renewal(args.owner_root, args.project)
        return
    if args.action in ('uninstall', 'remove'):
        if args.action == 'remove' and args.owner_root is None and args.api_port is None:
            state = cleanup_state()
            if state is None:
                print('No guard state: owned guard cleanup skipped')
                return
            args.owner_root = state.get('ownerRoot', '/opt/remnacust')
            ports = state.get('controlPorts', [])
            args.api_port = ports[0] if isinstance(ports, list) and ports else 0
        uninstall(args.owner_root, args.api_port, args.https_port)
        return
    if args.action == 'remove-control' and not (ROOT / 'state.json').exists():
        return
    import fcntl
    # A fixed root-owned directory avoids lock/file races across installers.
    if ROOT.is_symlink():
        raise ValueError('Unsafe guard directory')
    ROOT.mkdir(mode=0o700, exist_ok=True)
    if ROOT.stat().st_uid != 0 or ROOT.stat().st_mode & 0o022:
        raise ValueError('Unsafe guard directory')
    lock = os.open(ROOT / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, 'w') as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        if args.action == 'apply':
            ports = [value for value in (args.api_port, args.inbound_port) if value is not None] or None
            apply(args.panel, args.https_port, ports, args.owner_root)
        elif args.action == 'remove-control':
            state = json.loads((ROOT / 'state.json').read_text())
            if not args.owner_root or state.get('ownerRoot') != str(Path(args.owner_root).resolve()) or args.api_port not in state.get('controlPorts', []):
                return
            profile = Path('/etc/ufw/applications.d/remnacust-node-control')
            ufw = shutil.which('ufw')
            if ufw and profile.exists():
                control_access(state['panel'], state['controlPorts'], remove=True)
            state['controlPorts'] = []
            write(ROOT / 'state.json', json.dumps(state))
        elif args.action == 'site':
            site_access(args.https_port)
            if (ROOT / 'state.json').exists():
                state = json.loads((ROOT / 'state.json').read_text())
                try:
                    apply(state['panel'], args.https_port)
                except BaseException:
                    site_access(state.get('httpsPort', 0))
                    raise
        elif args.action == 'restore':
            state = json.loads((ROOT / 'state.json').read_text())
            ports, bridges = discover()
            replace_table(render(state['panel'], sorted(set(ports + state['sshPorts'])), bridges, state.get('httpsPort', 0)))
        elif args.action in ('acme-open', 'acme-close'):
            acme_window(args.action == 'acme-open')


if __name__ == '__main__':
    main()
