import argparse
import copy
import ipaddress
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


IMAGE = 'node:24.22.1-trixie-slim'
OWNER_LABEL = 'io.remnacust.test.panel-ipv6'
APPLICATIONS = ['api', 'worker', 'scheduler']
PRESERVED = ['db', 'cache', 'page', 'proxy', 'node']
TCP_SERVER = '''
const net = require('node:net');
net.createServer(s => s.end(process.env.FIXTURE_ROLE))
  .listen({host: '0.0.0.0', port: 18080});
'''
IPV6_SERVER = '''
const net = require('node:net');
net.createServer(s => s.end(process.env.FIXTURE_ROLE))
  .listen({host: '::', port: 18081, ipv6Only: true});
'''
TCP_PROBE = '''
const assert = require('node:assert/strict');
const dns = require('node:dns').promises;
const net = require('node:net');
const targets = JSON.parse(process.argv[1]);
const family = Number(process.argv[2]);
const port = family === 6 ? 18081 : 18080;
const deadline = Date.now() + 8000;
async function connect(target) {
  const resolved = await dns.lookup(target.host, {family});
  assert.equal(resolved.family, family);
  await new Promise((resolve, reject) => {
    const s = net.connect({host: resolved.address, port, family});
    let body = '';
    s.setTimeout(1000, () => s.destroy(new Error('TCP timeout')));
    s.on('error', reject);
    s.on('data', data => { body += data; });
    s.on('end', () => {
      try {
        assert.equal(s.remoteFamily, family === 6 ? 'IPv6' : 'IPv4');
        assert.equal(body, target.role);
        resolve();
      } catch (error) { reject(error); }
    });
  });
}
(async () => {
  for (const target of targets) {
    for (;;) {
      try { await connect(target); break; }
      catch (error) {
        if (Date.now() >= deadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    }
  }
  console.log(`PASS IPv${family} TCP ${targets.length} targets`);
})().catch(error => { console.error(error); process.exit(1); });
'''
ROUTE_PROBE = r'''
const fs = require('node:fs');
const routes4 = fs.readFileSync('/proc/net/route', 'utf8').trim().split('\n')
  .slice(1).map(line => line.trim().split(/\s+/)).filter(row => row[1] === '00000000');
const routes6 = fs.readFileSync('/proc/net/ipv6_route', 'utf8').trim().split('\n')
  .map(line => line.trim().split(/\s+/)).filter(row => row[0] === '0'.repeat(32)
    && row[1] === '00' && row[4] !== '0'.repeat(32) && row[9] !== 'lo');
console.log(JSON.stringify({ipv4: routes4.map(row => row[2]), ipv6: routes6.length}));
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def version(value):
    match = re.match(r'^v?(\d+)\.(\d+)(?:\.(\d+))?', value)
    require(match is not None, 'Unrecognized Docker/Compose version: ' + value)
    return tuple(int(part or 0) for part in match.groups())


def fixture(owner, legacy):
    services = {}
    for role in APPLICATIONS + PRESERVED:
        service = {
            'image': IMAGE, 'pull_policy': 'never',
            'command': ['node', '-e', TCP_SERVER],
            'environment': {'FIXTURE_ROLE': role},
            'labels': {OWNER_LABEL: owner},
            'networks': ['legacy'],
        }
        if role == 'page':
            service['labels']['io.remnacust.service-role'] = 'subscription-page'
        if role == 'node':
            service.pop('networks')
            service['network_mode'] = 'none'
        services[role] = service
    return {'services': services, 'networks': {'legacy': {'external': True, 'name': legacy}}}


def candidate(config, project):
    original = copy.deepcopy(config)
    result = runtime.panel_ipv6_config(config, APPLICATIONS + ['page'], True, project)
    require(config == original, 'Production transform mutated its input')
    require(result['networks']['legacy'] == original['networks']['legacy'], 'Legacy network changed')
    for role in PRESERVED:
        require(result['services'][role] == original['services'][role], role + ' configuration changed')
    for role in APPLICATIONS:
        require(runtime.PANEL_IPV6_NETWORK in result['services'][role]['networks'], role + ' lacks IPv6')
        require(result['services'][role].get('ports') == original['services'][role].get('ports'),
                role + ' published ports changed')
    return result


class DockerRegression:
    def __init__(self):
        self.owner = uuid.uuid4().hex
        self.project = 'rc-ipv6-' + self.owner[:16]
        self.legacy = self.project + '-legacy'
        self.started = time.monotonic()
        self.deadline = self.started + 90

    def command(self, *args, limit=20):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, 'Integration deadline exceeded')
        result = subprocess.run(['docker', *args], capture_output=True, text=True,
                                timeout=min(limit, remaining))
        require(result.returncode == 0,
                'docker ' + ' '.join(args[:3]) + ' failed: ' + result.stderr.strip())
        return result.stdout.strip()

    def preflight(self):
        server = json.loads(self.command('version', '--format', '{{json .Server}}'))
        require(server['Os'] == 'linux', 'A Linux Docker Engine is required')
        require(version(server['Version']) >= (28, 0, 0), 'Docker Engine >=28 is required')
        compose = self.command('compose', 'version', '--short')
        require(version(compose) >= (2, 33, 1), 'Docker Compose >=2.33.1 is required')
        self.command('image', 'inspect', IMAGE)
        print('Docker ' + server['Version'] + '; Compose ' + compose + '; cached ' + IMAGE, flush=True)

    def compose(self, *args, limit=20):
        return self.command('compose', '--project-name', self.project, '--file', str(self.path),
                            *args, limit=limit)

    def inspect_services(self):
        ids = self.compose('ps', '--all', '--quiet').splitlines()
        require(len(ids) == len(APPLICATIONS + PRESERVED), 'Missing fixture containers')
        containers = json.loads(self.command('inspect', *ids))
        result = {}
        for item in containers:
            labels = item['Config']['Labels']
            require(labels.get(OWNER_LABEL) == self.owner, 'Unexpected container ownership')
            require(item['State']['Running'], 'Fixture container stopped')
            require(not item['HostConfig']['PortBindings'], 'Fixture published a host port')
            require(not any((item['NetworkSettings']['Ports'] or {}).values()), 'Host binding unexpectedly created')
            result[labels['com.docker.compose.service']] = item
        require(set(result) == set(APPLICATIONS + PRESERVED), 'Unexpected fixture services')
        return result

    def probe(self, containers, family, targets):
        for role in APPLICATIONS:
            peers = [target for target in targets if target['role'] != role]
            output = self.command('exec', containers[role]['Id'], 'node', '-e', TCP_PROBE,
                                  json.dumps(peers), str(family), limit=12)
            print(role + ': ' + output, flush=True)

    def routes(self, container):
        return json.loads(self.command('exec', container['Id'], 'node', '-e', ROUTE_PROBE))

    def cleanup(self):
        self.deadline = self.started + 115
        failures = []
        for kind, listing, removing in (
                ('container', ('ps', '--all', '--quiet'), ('rm', '--force')),
                ('network', ('network', 'ls', '--quiet'), ('network', 'rm'))):
            try:
                ids = self.command(*listing, '--filter', 'label=' + OWNER_LABEL + '=' + self.owner).splitlines()
                if not ids:
                    continue
                items = json.loads(self.command(kind, 'inspect', *ids))
                for item in items:
                    labels = item['Config']['Labels'] if kind == 'container' else item['Labels']
                    require(labels.get(OWNER_LABEL) == self.owner, 'Refusing cleanup of unowned resource')
                self.command(*removing, *ids, limit=10)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                failures.append(str(error))
        require(not failures, 'Owned-resource cleanup failed: ' + '; '.join(failures))

    def run(self):
        with tempfile.TemporaryDirectory(prefix=self.project + '-') as folder:
            self.path = Path(folder) / 'compose.json'
            config = fixture(self.owner, self.legacy)
            ports_fixture = copy.deepcopy(config)
            ports_fixture['services']['api']['ports'] = [
                '127.0.0.1:13000:3000', {'host_ip': '127.0.0.1', 'published': '13001', 'target': 3001}]
            candidate(ports_fixture, self.project)
            enabled = candidate(config, self.project)
            enabled['networks'][runtime.PANEL_IPV6_NETWORK]['labels'][OWNER_LABEL] = self.owner
            peers4 = [{'host': role, 'role': role} for role in APPLICATIONS + PRESERVED if role != 'node']
            try:
                self.command('network', 'create', '--driver', 'bridge', '--label',
                             OWNER_LABEL + '=' + self.owner, self.legacy)
                legacy = json.loads(self.command('network', 'inspect', self.legacy))[0]
                require(not legacy['EnableIPv6'] and not legacy['Internal'], 'Legacy fixture must be IPv4 only')
                self.path.write_text(json.dumps(config), encoding='utf-8')
                self.compose('up', '--detach', '--no-build', '--pull', 'never', limit=35)
                before = self.inspect_services()
                self.probe(before, 4, peers4)
                routes4 = {role: self.routes(before[role])['ipv4'] for role in APPLICATIONS}
                require(all(routes4.values()), 'Legacy IPv4 default route missing')
                self.path.write_text(json.dumps(enabled), encoding='utf-8')
                self.compose('config', '--quiet')
                self.compose('up', '--detach', '--no-deps', '--no-build', '--pull', 'never',
                             *APPLICATIONS, limit=35)
                after = self.inspect_services()
                current_legacy = json.loads(self.command('network', 'inspect', self.legacy))[0]
                for key in ('Id', 'EnableIPv6', 'Internal', 'IPAM', 'Options'):
                    require(current_legacy[key] == legacy[key], 'Legacy network ' + key + ' changed')
                egress_name = self.project + '_' + runtime.PANEL_IPV6_NETWORK
                egress = json.loads(self.command('network', 'inspect', egress_name))[0]
                require(egress['EnableIPv6'] and not egress['EnableIPv4'] and not egress['Internal'],
                        'Additional network must be IPv6 only and non-internal')
                require(egress['Options'].get('com.docker.network.bridge.gateway_mode_ipv6') == 'nat',
                        'IPv6 NAT gateway mode missing')
                require(egress['Labels'].get(OWNER_LABEL) == self.owner, 'Egress ownership label missing')
                require(set(egress['Containers']) == {after[role]['Id'] for role in APPLICATIONS},
                        'Unexpected IPv6 network members')
                peers6 = []
                for role in APPLICATIONS:
                    networks = after[role]['NetworkSettings']['Networks']
                    require(set(networks) == {self.legacy, egress_name}, role + ' networks changed')
                    require(networks[self.legacy]['NetworkID'] == legacy['Id'], 'Primary network replaced')
                    endpoint = networks[egress_name]
                    require(not endpoint['IPAddress'], 'Egress network assigned IPv4')
                    address = ipaddress.IPv6Address(endpoint['GlobalIPv6Address'])
                    require(not address.is_link_local and not address.is_loopback, 'IPv6 address missing')
                    routes = self.routes(after[role])
                    require(routes['ipv4'] == routes4[role], 'Legacy IPv4 default gateway changed')
                    require(routes['ipv6'] > 0, role + ' IPv6 default route missing')
                    peers6.append({'host': str(address), 'role': role})
                    self.command('exec', '--detach', after[role]['Id'], 'node', '-e', IPV6_SERVER)
                for role in PRESERVED:
                    require(after[role]['Id'] == before[role]['Id'], role + ' container was recreated')
                    require(after[role]['NetworkSettings']['Networks'] == before[role]['NetworkSettings']['Networks'],
                            role + ' networks changed')
                self.probe(after, 4, peers4)
                self.probe(after, 6, peers6)
            finally:
                self.cleanup()
            print('PASS legacy IPv4 DNS/TCP and gateways; IPv6 TCP for API/worker/scheduler; '
                  'DB/cache/page/proxy/node unchanged; no host ports; owned resources cleaned. '
                  'Nonempty API ports preserved in config only. External IPv6 NAT egress NOT tested.', flush=True)


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--required', action='store_true', help='Fail if Linux Docker prerequisites are unavailable')
    mode.add_argument('--skip-unsupported', action='store_true', help='Explicitly allow a local prerequisite skip')
    args = parser.parse_args()
    test = DockerRegression()
    try:
        require(sys.platform == 'linux', 'This integration requires Linux; no Docker commands executed')
        test.preflight()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        print(('SKIP (explicit): ' if args.skip_unsupported else 'FAIL prerequisite: ') + str(error), flush=True)
        return 0 if args.skip_unsupported else 1
    def timeout(signum, frame):
        raise RuntimeError('120-second integration limit exceeded')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(max(1, int(120 - (time.monotonic() - test.started))))
    try:
        test.run()
        return 0
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    sys.exit(main())
