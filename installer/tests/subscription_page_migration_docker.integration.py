import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import subscription_pages as pages

suffix = uuid.uuid4().hex[:12]
project = 'rc-page-migrate-' + suffix
old = 'remnawave/subscription-page:fixture-' + suffix
new = 'rc-page-migration:good-' + suffix
bad = 'rc-page-migration:bad-' + suffix
custom_image = 'ghcr.io/lottman/remnacust-subscription-page:fixture-' + suffix


def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True, timeout=90).stdout.strip()


with tempfile.TemporaryDirectory(prefix='rc-page-migration-') as folder:
    root = Path(folder)
    os.environ['REMNACUST_ROOT'] = str(root)
    directory = root / 'legacy'
    directory.mkdir(mode=0o700)
    compose = directory / 'compose.json'
    base = ['compose', '--project-name', project, '-f', str(compose)]
    config = {'services': {
        'page': {'image': old, 'env_file': ['./.env'], 'volumes': ['./custom.json:/custom.json:ro'],
                 'healthcheck': {'test': ['CMD', 'node', '-e', 'fetch("http://127.0.0.1:3010").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'], 'interval': '1s', 'timeout': '2s', 'retries': 2}},
        'proxy': {'image': old, 'command': ['node', '-e', 'setInterval(()=>{},1000)']}},
        'networks': {'default': {'internal': True}}}
    compose.write_text(json.dumps(config))
    environment = b'REMNAWAVE_PANEL_URL=https://panel.example.test\nREMNAWAVE_API_TOKEN=fixture.private.token\n'
    (directory / '.env').write_bytes(environment)
    (directory / '.env').chmod(0o600)
    custom = b'{"theme":"keep-owner-content"}'
    (directory / 'custom.json').write_bytes(custom)
    dockerfile = root / 'Dockerfile'
    original_ready = pages.ready
    pages.ready = lambda item: original_ready(item, timeout=8)
    try:
        dockerfile.write_text('FROM node:24.22.1-trixie-slim\nLABEL org.opencontainers.image.version="3.4.8"\nCMD ' + json.dumps(['node', '-e', 'require("http").createServer((q,r)=>r.end("ok")).listen(3010)']) + '\n')
        docker('build', '--network=none', '--pull=false', '-t', old, str(root))
        dockerfile.write_text('FROM ' + old + '\nLABEL org.opencontainers.image.version="1.1.7.106"\n')
        docker('build', '--network=none', '--pull=false', '-t', new, str(root))
        dockerfile.write_text('FROM ' + new + '\nCMD ["node","-e","process.exit(1)"]\n')
        docker('build', '--network=none', '--pull=false', '-t', bad, str(root))
        docker(*base, 'up', '-d', '--pull', 'never')
        proxy = docker(*base, 'ps', '-q', 'proxy')
        proxy_started = json.loads(docker('inspect', proxy))[0]['State']['StartedAt']

        def source():
            return docker(*base, 'ps', '--all', '-q', 'page')

        original_ready({'directory': str(directory), 'project': project, 'service': 'page', 'composeFiles': [str(compose)]}, timeout=8)
        page = pages.migrate(root, source(), new, '1.1.7.106', 'v1.2.152')
        item = pages.selected(root, page)
        compose = Path(item['composeFiles'][0])
        base = pages.compose_base(item)[1:]
        assert pages.inspect(item)['Config']['Image'] == new and pages.inspect(item)['State']['Running']
        assert (directory / '.env').read_bytes() == environment
        assert (directory / 'custom.json').read_bytes() == custom
        assert docker(*base, 'ps', '-q', 'proxy') == proxy
        assert json.loads(docker('inspect', proxy))[0]['State']['StartedAt'] == proxy_started
        assert not pages.migration_candidates(root, container=source())

        config = pages.runtime.load(compose)
        config['services']['page']['image'] = old
        pages.runtime.write(compose, config)
        docker(*base, 'up', '-d', '--no-deps', '--pull', 'never', 'page')
        docker(*base, 'stop', 'page')
        pages.migrate(root, source(), new, '1.1.7.106', 'v1.2.152')
        assert not pages.inspect(pages.selected(root, page))['State']['Running']

        config = pages.runtime.load(compose)
        config['services']['page']['image'] = old
        pages.runtime.write(compose, config)
        docker(*base, 'up', '-d', '--no-deps', '--pull', 'never', 'page')
        original_ready(pages.selected(root, page), timeout=8)
        try:
            pages.migrate(root, source(), bad, '1.1.7.106', 'v1.2.152')
            raise AssertionError('Broken migration reported success')
        except ValueError as error:
            assert str(error) == 'PAGE_NOT_READY', str(error)
        restored = pages.inspect(pages.selected(root, page))
        assert restored['Config']['Image'] == old and restored['State']['Running']
        original_ready(pages.selected(root, page), timeout=8)
        assert (directory / '.env').read_bytes() == environment
        assert (directory / 'custom.json').read_bytes() == custom
        assert docker(*base, 'ps', '-q', 'proxy') == proxy
        dockerfile.write_text('FROM ' + old + '\nLABEL org.opencontainers.image.version="1.1.7.4"\n')
        docker('build', '--network=none', '--pull=false', '-t', custom_image, str(root))
        config = pages.runtime.load(compose)
        config['services']['page']['image'] = custom_image
        pages.runtime.write(compose, config)
        docker(*base, 'up', '-d', '--no-deps', '--pull', 'never', 'page')
        original_ready(pages.selected(root, page), timeout=8)
        pages.migrate(root, source(), new, '1.1.7.106', 'v1.2.152')
        assert pages.inspect(pages.selected(root, page))['Config']['Image'] == new
        assert (directory / '.env').read_bytes() == environment
        assert (directory / 'custom.json').read_bytes() == custom
        assert json.loads(docker('inspect', proxy))[0]['State']['StartedAt'] == proxy_started
        literal = 'https://panel-$REMNACUST_RETAINED_URL.example.test'
        os.environ['REMNACUST_RETAINED_URL'] = 'must-not-expand'
        config = pages.runtime.load(compose)
        config['services']['page']['image'] = custom_image
        config['services']['page']['environment']['REMNAWAVE_PANEL_URL'] = literal.replace('$', '$$')
        pages.runtime.write(compose, config)
        docker(*base, 'up', '-d', '--no-deps', '--pull', 'never', 'page')
        original_ready(pages.selected(root, page), timeout=8)
        pages.migrate(root, source(), new, '1.1.7.106', 'v1.2.152')
        assert pages.runtime.environment(pages.inspect(pages.selected(root, page)))['REMNAWAVE_PANEL_URL'] == literal
        assert (directory / '.env').read_bytes() == environment
        print('PASS real Docker migration: early custom adoption and legacy version namespace, running/stopped, isolated service, env/mount preservation and failed-health rollback')
    finally:
        subprocess.run(['docker', *base, '--profile', '*', 'down', '--volumes', '--remove-orphans'], capture_output=True, timeout=90)
        for image in (custom_image, bad, new, old):
            subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)
