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
good, bad = 'rc-page-fixture:' + suffix, 'rc-page-fixture-bad:' + suffix
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
        print('PASS real Docker: install, loopback HTTP, private env, list, stop, stopped update, start and rollback without credential changes')
    finally:
        if not page:
            registered = pages.records(root)
            if len(registered) == 1:
                page = next(iter(registered))
        if page:
            subprocess.run([*pages.compose_base(pages.selected(root, page)), 'down', '--remove-orphans'], capture_output=True, timeout=90)
        for image in (bad, good):
            subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)
