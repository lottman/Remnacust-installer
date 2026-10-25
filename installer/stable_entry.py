#!/usr/bin/env python3
"""Manage a dedicated TCP entry; backend selection happens on each connection."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path('/etc/remnacust-entry')
UNIT = Path('/etc/systemd/system/remnacust-entry.service')


def render(config):
    if set(config) != {'listenPort', 'strategy', 'backends'}:
        raise ValueError('Invalid entry fields')
    port = config['listenPort']
    if type(port) is not int or not 1 <= port <= 65535 or port == 22:
        raise ValueError('Invalid entry port')
    strategy = config['strategy']
    if strategy not in {'priority', 'roundRobin', 'leastConnections'}:
        raise ValueError('Invalid strategy')
    backends = config['backends']
    if not isinstance(backends, list) or not 1 <= len(backends) <= 128:
        raise ValueError('Select 1–128 backends')
    lines = []
    seen = set()
    for index, backend in enumerate(backends):
        if set(backend) != {'address', 'port'}:
            raise ValueError('Invalid backend fields')
        address = ipaddress.ip_address(backend['address'])
        if address.is_unspecified or address.is_multicast or address.is_loopback or address.is_link_local:
            raise ValueError('Use a routable backend address')
        target = backend['port']
        if type(target) is not int or not 1 <= target <= 65535 or target == 22:
            raise ValueError('Invalid backend port')
        endpoint = (str(address), target)
        if endpoint in seen:
            raise ValueError('Duplicate backend')
        seen.add(endpoint)
        host = f'[{address}]' if address.version == 6 else str(address)
        backup = ' backup' if strategy == 'priority' and index else ''
        lines.append(f'    server node{index + 1} {host}:{target} check inter 2s fall 2 rise 2{backup}')
    balance = 'leastconn' if strategy == 'leastConnections' else 'roundrobin'
    return f'''global
    user nobody
    group nogroup
    maxconn 10000
    hard-stop-after 1h
defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    retries 2
    option redispatch
frontend entry
    bind :{port}
    bind :::{port} v6only
    default_backend nodes
backend nodes
    balance {balance}
''' + '\n'.join(lines) + '\n'


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, timeout=30, check=check)


def write(path, data):
    if path.is_symlink():
        raise ValueError('Unsafe entry file')
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.entry-')
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(data)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def apply(config):
    import fcntl
    rules = render(config)
    if ROOT.is_symlink():
        raise ValueError('Unsafe entry directory')
    ROOT.mkdir(mode=0o700, exist_ok=True)
    if ROOT.stat().st_uid != 0 or ROOT.stat().st_mode & 0o022:
        raise ValueError('Unsafe entry directory')
    fd = os.open(ROOT / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = ROOT / 'haproxy.cfg'
        for item in [path, UNIT]:
            if item.is_symlink():
                raise ValueError('Unsafe entry file')
        old_config = path.read_text() if path.exists() else None
        old_unit = UNIT.read_text() if UNIT.exists() else None
        unit = '''[Unit]
Description=Remnacust stable TCP entry
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/sbin/haproxy -Ws -f /etc/remnacust-entry/haproxy.cfg -p /run/remnacust-entry/haproxy.pid
ExecReload=/usr/sbin/haproxy -c -f /etc/remnacust-entry/haproxy.cfg
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=mixed
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RuntimeDirectory=remnacust-entry
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_SYS_CHROOT
[Install]
WantedBy=multi-user.target
'''
        active = run('systemctl', 'is-active', '--quiet', 'remnacust-entry.service', check=False).returncode == 0
        try:
            # HAProxy parses the candidate before replacing the live file.
            with tempfile.NamedTemporaryFile(mode='w', dir=ROOT, prefix='.validate-') as candidate:
                candidate.write(rules); candidate.flush()
                run('/usr/sbin/haproxy', '-c', '-f', candidate.name)
            write(path, rules); write(UNIT, unit)
            run('systemctl', 'daemon-reload')
            run('systemctl', 'enable', 'remnacust-entry.service')
            run('systemctl', 'reload' if active else 'start', 'remnacust-entry.service')
            run('systemctl', 'is-active', '--quiet', 'remnacust-entry.service')
        except Exception:
            for item, old in [(path, old_config), (UNIT, old_unit)]:
                if old is None:
                    item.unlink(missing_ok=True)
                else:
                    write(item, old)
            run('systemctl', 'daemon-reload', check=False)
            if active:
                run('systemctl', 'reload', 'remnacust-entry.service', check=False)
            elif old_unit is None:
                run('systemctl', 'disable', '--now', 'remnacust-entry.service', check=False)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['apply', 'render'])
    parser.add_argument('--config', type=Path, required=True)
    args = parser.parse_args()
    if args.config.stat().st_size > 65536:
        raise ValueError('Entry configuration too large')
    config = json.loads(args.config.read_text())
    if args.action == 'render':
        print(render(config))
    else:
        if os.geteuid() != 0:
            raise SystemExit('Root is required')
        apply(config)


if __name__ == '__main__':
    main()
