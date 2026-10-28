#!/usr/bin/env python3
"""Own only the node guard table; keep SSH and outbound reply traffic available."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

TABLE = 'remnacust_node_guard'
ROOT = Path('/etc/remnacust-node-firewall')
UNIT = Path('/etc/systemd/system/remnacust-node-firewall.service')


def run(*args, check=True, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True,
                          check=check, timeout=30)


def network(value):
    result = ipaddress.ip_network(value, strict=False)
    if result.prefixlen == 0 or result.is_multicast or result.is_unspecified:
        raise ValueError('A specific panel IP or subnet is required')
    return str(result)


def render(panel, ssh_ports, bridges):
    panel = network(panel)
    ports = sorted(set(ssh_ports) | {22})
    if len(ports) > 64 or any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
        raise ValueError('Invalid SSH ports')
    if len(bridges) > 128 or any(not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', b) for b in bridges):
        raise ValueError('Invalid Docker bridge')
    family = 'ip6' if ':' in panel else 'ip'
    source = f'{family} saddr {panel} accept'
    trusted = ('iifname { ' + ', '.join(json.dumps(b) for b in sorted(set(bridges))) + ' } accept') if bridges else ''
    return f'''table inet {TABLE} {{
 set acme_http {{ type inet_service; flags timeout; }}
 chain input {{
  type filter hook input priority -10; policy accept;
  iifname "lo" accept
  ct state invalid drop
  {source}
  tcp dport {{ {', '.join(map(str, ports))} }} accept
  tcp dport @acme_http accept
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


def write(path, value):
    if path.is_symlink():
        raise ValueError('Refusing a symlink')
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.guard-')
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(value)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply(panel):
    panel = network(panel)
    if ROOT.is_symlink() or (ROOT.exists() and
                            (ROOT.stat().st_uid != 0 or ROOT.stat().st_mode & 0o022)):
        raise ValueError('Unsafe guard directory')
    ROOT.mkdir(mode=0o700, exist_ok=True)
    ports, bridges = discover()
    rules = render(panel, ports, bridges)
    previous = run('nft', 'list', 'table', 'inet', TABLE, check=False)
    paths = [ROOT / 'guard.py', ROOT / 'state.json', UNIT]
    for path in paths:
        if path.is_symlink():
            raise ValueError('Unsafe guard file')
    old = {path: path.read_text() if path.exists() else None for path in paths}
    try:
        write(ROOT / 'guard.py', Path(__file__).read_text())
        write(ROOT / 'state.json', json.dumps({'panel': panel, 'sshPorts': ports}))
        write(UNIT, '''[Unit]
Description=Remnacust node source guard
After=network-pre.target docker.service
Before=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /etc/remnacust-node-firewall/guard.py restore
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
''')
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', 'remnacust-node-firewall.service')
        replace_table(rules)
    except Exception:
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
    parser.add_argument('action', choices=['apply', 'restore', 'remove', 'render', 'acme-open', 'acme-close'])
    parser.add_argument('--panel')
    args = parser.parse_args()
    if args.action == 'render':
        print(render(args.panel, [22], []))
        return
    if os.geteuid() != 0:
        raise SystemExit('Root is required')
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
            apply(args.panel)
        elif args.action == 'restore':
            state = json.loads((ROOT / 'state.json').read_text())
            ports, bridges = discover()
            replace_table(render(state['panel'], sorted(set(ports + state['sshPorts'])), bridges))
        elif args.action in ('acme-open', 'acme-close'):
            acme_window(args.action == 'acme-open')
        else:
            run('systemctl', 'disable', 'remnacust-node-firewall.service', check=False)
            replace_table('')
            UNIT.unlink(missing_ok=True)
            run('systemctl', 'daemon-reload')
            print('Owned guard removed; other firewall rules were not changed')


if __name__ == '__main__':
    main()
