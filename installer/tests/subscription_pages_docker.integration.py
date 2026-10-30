"""Exercise deployment, isolated update and rollback with disposable HTTP fixtures."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from urllib.request import urlopen
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import subscription_pages as pages

suffix = uuid.uuid4().hex[:12]
project = 'rc-page-test-' + suffix
retired_project = project + '-retired'
good, bad = 'rc-page-fixture:' + suffix, 'rc-page-fixture-bad:' + suffix
owned = 'ghcr.io/lottman/remnacust-subscription-page:audit-' + suffix
with tempfile.TemporaryDirectory(prefix='remnacust-pages-docker-') as folder:
    root = Path(folder)
    os.environ['REMNACUST_ROOT'] = str(root)
    (root / 'node').write_text('#!/bin/sh\nexec wget -q -O /dev/null http://127.0.0.1:3010/internal/health\n')
    server = "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok' | nc -l -p 3010; done"
    (root / 'Dockerfile').write_text('FROM alpine:3.22\nCOPY node /usr/local/bin/node\nRUN chmod 755 /usr/local/bin/node\nCMD ' + json.dumps(['sh', '-c', server]) + '\n')
    def docker(*args):
        return subprocess.run(['docker', *args], check=True, text=True, capture_output=True, timeout=90)
    def diagnostic_command(base, *args, **kwargs):
        result = subprocess.run([*base, *args], text=True, capture_output=True, timeout=180)
        if result.returncode:
            raise ValueError('Docker fixture failure: ' + result.stderr[-2000:])
        return result.stdout
    pages.command = diagnostic_command
    page = None
    try:
        docker('build', '--network=none', '-t', good, str(root))
        (root / 'Dockerfile').write_text('FROM ' + good + '\nCMD ["sh","-c","exit 1"]\n')
        docker('build', '--network=none', '-t', bad, str(root))
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        page = pages.install(root, root / 'site', project, 'https://panel.example.test', 'fixture.token.value', port, good, 'sub.example.test')
        assert urlopen('http://127.0.0.1:' + str(port) + '/internal/health', timeout=5).read().strip() == b'ok'
        item = pages.selected(root, page)
        original_env = (root / 'site/.env').read_bytes()
        assert (root / 'site/.env').stat().st_mode & 0o077 == 0
        assert pages.listing(root)[0]['running']
        assert pages.reuse_port(root, port)['id'] == page
        docker('tag', good, owned)
        pages.upgrade(root, page, owned, '1.1.7.58', 'v1.2.93')
        (root / 'registry/subscription-pages' / (page + '.json')).unlink()
        assert pages.reuse_port(root, port)['id'] == page, 'owned listener was not recovered'
        assert pages.selected(root, page)['domain'] == 'sub.example.test'
        assert (root / 'site/.env').read_bytes() == original_env
        pages.upgrade(root, page, good, '1.1.7.58', 'v1.2.93')
        assert urlopen('http://127.0.0.1:' + str(port) + '/internal/health', timeout=5).read().strip() == b'ok'
        pages.service(root, page, 'stop')
        pages.upgrade(root, page, good, '1.1.7.58', 'v1.2.93')
        assert not pages.listing(root)[0]['running'], 'stopped page was started by update'
        pages.service(root, page, 'start')
        try:
            pages.upgrade(root, page, bad, '1.1.7.58', 'v1.2.93')
            raise AssertionError('broken page passed readiness')
        except ValueError as error:
            assert str(error) == 'PAGE_NOT_READY'
        pages.ready(pages.selected(root, page))
        assert pages.inspect(pages.selected(root, page))['Config']['Image'] == good
        assert (root / 'site/.env').read_bytes() == original_env
        # An unrelated container in the same project must retain its identity.
        config = pages.runtime.load(root / 'site/docker-compose.yml')
        config['services']['database'] = {'image': good, 'command': ['sleep', '3600']}
        pages.runtime.write(root / 'site/docker-compose.yml', config)
        docker('compose', '--project-name', project, '-f', str(root / 'site/docker-compose.yml'), 'up', '-d', '--no-deps', 'database')
        database_id = docker('compose', '--project-name', project, '-f', str(root / 'site/docker-compose.yml'), 'ps', '-q', 'database').stdout.strip()
        before_delete = pages.selected(root, page)
        backup = pages.uninstall(root, page)
        assert Path(backup, 'compose-files.before.json').is_file()
        assert pages.inspect(before_delete) is None
        assert not pages.listing(root)
        assert (root / 'site/.env').read_bytes() == original_env
        docker('compose', '--project-name', project, '-f', str(root / 'site/docker-compose.yml'), 'up', '-d', '--no-build', '--pull', 'never')
        assert pages.inspect(before_delete) is None, 'normal compose up resurrected removed page'
        assert docker('inspect', '--format', '{{.State.Running}}', database_id).stdout.strip() == 'true'
        # The standalone proxy is owned explicitly; its volume must survive.
        retired_dir = root / 'retired'
        retired_page = pages.install(root, retired_dir, retired_project, 'https://panel.example.test', 'fixture.token.value', port, good, 'sub.example.test')
        retired_item = pages.selected(root, retired_page)
        cfg = pages.runtime.load(retired_dir / 'docker-compose.yml')
        cfg['services']['caddy'] = {'image': good, 'command': ['sleep', '3600'], 'volumes': ['certificate-data:/data']}
        cfg['volumes'] = {'certificate-data': {}}
        pages.runtime.write(retired_dir / 'docker-compose.yml', cfg)
        retired_item['ownedServices'] = ['subscription-page', 'caddy']
        pages.runtime.write(root / 'registry/subscription-pages' / (retired_page + '.json'), retired_item)
        docker('compose', '--project-name', retired_project, '-f', str(retired_dir / 'docker-compose.yml'), 'up', '-d', 'caddy')
        pages.uninstall(root, retired_page)
        assert pages.inspect(retired_item) is None
        assert pages.inspect({**retired_item, 'service': 'caddy'}) is None
        docker('volume', 'inspect', retired_project + '_certificate-data')
        pages.install(root, retired_dir, retired_project, 'https://panel.example.test', 'new.fixture.token', port, good, 'new.example.test')
        archives = list((root / 'backups').glob('reinstalled-subscription-page-*/configuration/.env'))
        assert len(archives) == 1 and b'fixture.token.value' in archives[0].read_bytes()
        assert b'new.fixture.token' in (retired_dir / '.env').read_bytes()
        print('PASS real Docker: owned-port recovery, install/update/rollback, isolated uninstall, retained env/database/volume, no resurrection, dedicated proxy removal and reinstall')
    finally:
        if not page:
            registered = pages.records(root)
            if len(registered) == 1:
                page = next(iter(registered))
        if page:
            subprocess.run(['docker', 'compose', '--project-name', project, '-f', str(root / 'site/docker-compose.yml'), '--profile', '*', 'down', '--remove-orphans'], capture_output=True, timeout=90)
        if (root / 'retired/docker-compose.yml').is_file():
            subprocess.run(['docker', 'compose', '--project-name', retired_project, '-f', str(root / 'retired/docker-compose.yml'), '--profile', '*', 'down', '--remove-orphans'], capture_output=True, timeout=90)
        subprocess.run(['docker', 'volume', 'rm', retired_project + '_certificate-data'], capture_output=True, timeout=30)
        for image in (bad, owned, good):
            subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)
