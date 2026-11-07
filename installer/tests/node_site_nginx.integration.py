import hashlib
from html.parser import HTMLParser
import http.client
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import types
from urllib.parse import quote, urljoin, urlsplit
import uuid


SOURCE = Path(__file__).resolve().parents[1]
HOSTNAME = 'node.example.com'
PROXY = b'PROXY TCP4 192.0.2.10 192.0.2.20 40123 443\r\n'
IMAGE = os.environ.get('IMAGE', 'nginx:1.28-alpine')


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.policies = []
        self.resources = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'meta' and attrs.get('http-equiv', '').lower() == 'content-security-policy':
            self.policies.append(attrs.get('content', ''))
        key = 'href' if tag == 'link' else 'src' if tag in {'script', 'img'} else None
        if key and attrs.get(key):
            self.resources.append(attrs[key])


def load_module(name, source, location=None):
    module = types.ModuleType(name)
    module.__file__ = str(location or source)
    exec(compile(source.read_text(encoding='utf-8'), str(source), 'exec'), module.__dict__)
    return module


class Fixture:
    def __init__(self, root):
        self.root = root
        self.token = uuid.uuid4().hex
        self.deadline = time.monotonic() + 120
        self.containers = set()
        self.pending = set()
        self.connections = set()
        self.docker_seconds = 0
        self.sequence = 0
        self.deploy = root / 'node'
        self.backups = root / 'backups'
        self.run = root / 'run'
        self.certs = root / 'certs'
        self.helper = root / 'helpers'
        for path in [self.run, self.certs, self.helper]:
            path.mkdir(mode=0o700)
        self.catalog = (SOURCE / 'node-sites.json').read_bytes()
        (self.helper / 'node_site_catalog.py').write_bytes((SOURCE / 'node_site_catalog.py').read_bytes())
        self.site = load_module('isolated_node_site', SOURCE / 'node_site.py', self.helper / 'node_site.py')
        assert {'schema': 1, 'sites': list(self.site._load_catalog().values())} == json.loads(self.catalog)
        self.runtime = load_module('isolated_runtime', SOURCE / 'runtime.py')
        self.command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                     '-keyout', str(self.certs / 'privkey.pem'), '-out', str(self.certs / 'fullchain.pem'),
                     '-days', '1', '-subj', '/CN=' + HOSTNAME,
                     '-addext', 'subjectAltName=DNS:' + HOSTNAME)
        (root / 'server.conf').write_text(self.runtime.nginx_config(HOSTNAME), encoding='utf-8')
        (root / 'nginx.conf').write_text(
            'user nginx;\nworker_processes 1;\npid /tmp/nginx.pid;\nerror_log /dev/stderr warn;\n'
            'events { worker_connections 64; }\nhttp {\n'
            'include /etc/nginx/mime.types;\ndefault_type application/octet-stream;\n'
            'access_log off;\nkeepalive_timeout 10;\ninclude /etc/nginx/conf.d/default.conf;\n}\n',
            encoding='utf-8')
        self.context = ssl.create_default_context(cafile=str(self.certs / 'fullchain.pem'))
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.set_alpn_protocols(['http/1.1'])

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Node website integration exceeded 120 seconds')
        return remaining

    def command(self, *args):
        started = time.monotonic()
        try:
            return subprocess.run(args, check=True, capture_output=True, text=True,
                                  timeout=min(15, self.remaining())).stdout.strip()
        finally:
            if args[0] == 'docker':
                self.docker_seconds += time.monotonic() - started

    def start(self):
        self.sequence += 1
        name = 'remnacust-site-' + self.token + '-' + str(self.sequence)
        self.pending.add(name)
        mounts = [
            (self.root / 'nginx.conf', '/etc/nginx/nginx.conf', True),
            (self.root / 'server.conf', '/etc/nginx/conf.d/default.conf', True),
            (self.deploy / 'www', '/usr/share/nginx/html', True),
            (self.certs, '/var/lib/remnacust/tls', True),
            (self.run, '/var/lib/remnacust/run', False),
        ]
        args = ['docker', 'run', '-d', '--pull', 'never', '--network', 'none',
                '--name', name, '--label', 'remnacust.node-site-test=' + self.token,
                '--entrypoint', 'nginx']
        for source, target, readonly in mounts:
            args += ['--mount', 'type=bind,src=' + str(source) + ',dst=' + target +
                     (',readonly' if readonly else '')]
        identifier = self.command(*args, IMAGE, '-g', 'daemon off;')
        if not re.fullmatch(r'[a-f0-9]{64}', identifier):
            raise AssertionError('Docker did not return the owned container ID')
        self.containers.add(identifier)
        self.pending.remove(name)
        return identifier

    def stop(self, identifier):
        if identifier not in self.containers:
            raise AssertionError('Refusing to remove an unowned container')
        self.command('docker', 'rm', '-f', identifier)
        self.containers.remove(identifier)
        (self.run / 'nginx.sock').unlink(missing_ok=True)

    def connect(self, hostname=HOSTNAME, proxy=True):
        raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        raw.settimeout(min(2, self.remaining()))
        try:
            raw.connect(str(self.run / 'nginx.sock'))
            if proxy:
                raw.sendall(PROXY)
            secured = self.context.wrap_socket(raw, server_hostname=hostname)
        except BaseException:
            raw.close()
            raise
        connection = http.client.HTTPConnection(HOSTNAME, timeout=2)
        connection.sock = secured
        self.connections.add(connection)
        return connection

    def ready(self):
        deadline = min(self.deadline, time.monotonic() + 6)
        while True:
            try:
                return self.connect()
            except (OSError, ssl.SSLError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.025)

    def request(self, connection, path, status=200, expected=None):
        self.remaining()
        connection.request('GET', path, headers={'Host': HOSTNAME, 'Accept-Encoding': 'identity'})
        response = connection.getresponse()
        body = response.read(2 * 1024 * 1024 + 1)
        assert len(body) <= 2 * 1024 * 1024, path
        assert response.status == status, (path, response.status, body[:160])
        assert response.getheader('Server') == 'nginx', response.getheaders()
        assert response.getheader('X-Content-Type-Options') == 'nosniff'
        assert response.getheader('Referrer-Policy') == 'strict-origin-when-cross-origin'
        assert response.getheader('Content-Security-Policy') is None
        if status == 403:
            assert not re.search(rb'nginx/[0-9]', body)
        if expected is not None:
            assert body == expected, (path, len(body), len(expected))
        return body

    def check_transport(self, identifier):
        inspected = json.loads(self.command('docker', 'inspect', identifier))[0]
        assert inspected['HostConfig']['NetworkMode'] == 'none'
        assert not inspected['HostConfig'].get('PortBindings')
        assert not any(inspected['NetworkSettings']['Ports'].values())
        try:
            connection = self.connect(hostname='wrong.example.com')
        except ssl.SSLCertVerificationError:
            pass
        else:
            connection.close()
            raise AssertionError('TLS hostname verification was bypassed')
        try:
            connection = self.connect(proxy=False)
        except (OSError, ssl.SSLError):
            pass
        else:
            connection.close()
            raise AssertionError('TLS without the required PROXY header was accepted')

    def check_site(self, connection, files):
        self.request(connection, '/', expected=files['index.html'].encode('utf-8'))
        for name, content in files.items():
            self.request(connection, '/' + quote(name, safe='/._-'), expected=content.encode('utf-8'))
            if name.endswith('.html'):
                parsed = Page()
                parsed.feed(content)
                assert len(parsed.policies) == 1 and "script-src 'self'" in parsed.policies[0]
                assert 'frame-ancestors' not in parsed.policies[0]
        missing = '/missing/nested/page.html'
        body = self.request(connection, missing, 404, files['404.html'].encode('utf-8'))
        parsed = Page()
        parsed.feed(body.decode('utf-8'))
        assert parsed.resources
        for resource in parsed.resources:
            assert resource.startswith('/') and not resource.startswith('//'), resource
            path = urlsplit(urljoin('https://' + HOSTNAME + missing, resource)).path
            assert path.lstrip('/') in files, resource
            self.request(connection, path, expected=files[path.lstrip('/')].encode('utf-8'))
        for path in ['/.env', '/.node-site.json', '/.node-site-transaction.json', '/assets/.private']:
            self.request(connection, path, 403)
        self.request(connection, '/node-site-backup.json', 404, files['404.html'].encode('utf-8'))
        assert not (self.deploy / 'www' / self.site.STATE_NAME).exists()
        assert not (self.deploy / 'www' / self.site.JOURNAL_NAME).exists()
        assert not (self.deploy / 'www' / self.site.RECEIPT_NAME).exists()
        state = self.deploy / self.site.STATE_NAME
        assert state.is_file() and state.stat().st_mode & 0o777 == 0o600

    def diagnostics(self):
        for identifier in self.containers:
            result = subprocess.run(['docker', 'logs', '--tail', '30', identifier],
                                    capture_output=True, text=True, timeout=5)
            print(result.stdout + result.stderr, file=sys.stderr)

    def cleanup(self):
        for connection in self.connections:
            connection.close()
        failures = []
        for identifier in list(self.containers):
            result = subprocess.run(['docker', 'rm', '-f', identifier],
                                    capture_output=True, text=True, timeout=8)
            if result.returncode:
                failures.append(identifier)
            else:
                self.containers.remove(identifier)
        for name in self.pending:
            inspected = subprocess.run(['docker', 'inspect', name],
                                       capture_output=True, text=True, timeout=5)
            if inspected.returncode:
                continue
            data = json.loads(inspected.stdout)[0]
            if data['Config']['Labels'].get('remnacust.node-site-test') != self.token:
                failures.append(name)
                continue
            subprocess.run(['docker', 'rm', '-f', data['Id']], check=True,
                           capture_output=True, text=True, timeout=8)
        if failures:
            raise AssertionError('Unable to remove owned fixture containers: ' + ', '.join(failures))


def main():
    if not sys.platform.startswith('linux'):
        raise SystemExit('Run this isolated integration on native Linux or WSL')
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='remnacust-site-nginx-') as directory:
        fixture = Fixture(Path(directory))
        try:
            fixture.command('docker', 'image', 'inspect', IMAGE)
            templates = fixture.site.TEMPLATES
            assert len(templates) == 20
            for index, identifier in enumerate(templates):
                installed = fixture.site.install_site(fixture.deploy, HOSTNAME, template=identifier,
                                                      replace=index > 0, backup_root=fixture.backups)
                assert installed['changed']
                container = fixture.start()
                connection = fixture.ready()
                try:
                    if index == 0:
                        fixture.check_transport(container)
                    files = fixture.site.render_site(HOSTNAME, identifier)
                    fixture.check_site(connection, files)
                finally:
                    connection.close()
                fixture.stop(container)
                if (index + 1) % 5 == 0:
                    print('PASS Unix PROXY/TLS exact HTTP assets: ' + str(index + 1) + '/20', flush=True)
            owner = b'<!doctype html><title>Owner website</title><script>window.owner=true;</script><p>Preserve owner edits</p>'
            (fixture.deploy / 'www' / 'index.html').write_bytes(owner)
            (fixture.deploy / 'www' / 'owner.css').write_bytes(b'body { color: navy; }\n')
            challenge = fixture.deploy / 'www' / '.well-known' / 'acme-challenge' / 'token'
            challenge.parent.mkdir(parents=True)
            challenge.write_bytes(b'owner-local-challenge')
            before = {str(path.relative_to(fixture.deploy / 'www')): path.read_bytes()
                      for path in (fixture.deploy / 'www').rglob('*') if path.is_file()}
            container = fixture.start()
            connection = fixture.ready()
            fixture.request(connection, '/', expected=owner)
            fixture.request(connection, '/.well-known/acme-challenge/token', expected=b'owner-local-challenge')
            fixture.request(connection, '/.well-known/.env', 403)
            replacement = fixture.site.install_site(fixture.deploy, HOSTNAME, template=templates[0],
                                                    replace=True, backup_root=fixture.backups)
            fixture.request(connection, '/', expected=owner)
            connection.close()
            fixture.stop(container)
            container = fixture.start()
            connection = fixture.ready()
            fixture.request(connection, '/', expected=fixture.site.render_site(HOSTNAME, templates[0])['index.html'].encode('utf-8'))
            fixture.site.restore_site(fixture.deploy, replacement['backup'], replacement['generation'], fixture.backups)
            fixture.request(connection, '/', expected=fixture.site.render_site(HOSTNAME, templates[0])['index.html'].encode('utf-8'))
            connection.close()
            fixture.stop(container)
            container = fixture.start()
            connection = fixture.ready()
            try:
                fixture.request(connection, '/', expected=owner)
                for name, content in before.items():
                    fixture.request(connection, '/' + quote(name, safe='/._-'), expected=content)
                after = {str(path.relative_to(fixture.deploy / 'www')): path.read_bytes()
                         for path in (fixture.deploy / 'www').rglob('*') if path.is_file()}
                assert after == before
                assert not (fixture.deploy / 'www' / fixture.site.STATE_NAME).exists()
            finally:
                connection.close()
            fixture.stop(container)
            print('PASS atomic publication requires nginx remount; guarded rollback restores exact owner content', flush=True)
            print('PASS 20 sites, verified TLS/PROXY, branded nested 404, hidden files, headers and CSP compatibility; '
                  + f'Docker commands {fixture.docker_seconds:.1f}s, total {time.monotonic() - started:.1f}s; '
                  + 'catalog sha256=' + hashlib.sha256(fixture.catalog).hexdigest(), flush=True)
        except BaseException:
            fixture.diagnostics()
            raise
        finally:
            fixture.cleanup()


if __name__ == '__main__':
    main()
