"""Real isolated Compose page replacement and rollback; no public ports or VPN."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import subscription_migration as migration


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError('Isolated Compose fixture command failed: ' + args[0])
    return result.stdout.strip()


def main():
    nonce = uuid.uuid4().hex[:12]
    project = 'remnacust-page-audit-' + nonce
    old_image = 'remnawave/subscription-page:audit-' + nonce
    new_image = 'remnacust-subscription-page:audit-' + nonce
    base_image = os.environ.get('REMNACUST_SUBPAGE_TEST_IMAGE', 'alpine:3.22')
    run('docker', 'image', 'inspect', base_image)
    run('docker', 'tag', base_image, old_image)
    run('docker', 'tag', base_image, new_image)
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        root = Path(temporary); page = root / 'page'; panel = root / 'panel'
        page.mkdir(); panel.mkdir(); os.environ['REMNACUST_ROOT'] = str(root)
        compose = page / 'compose.json'; state = root / 'state.json'; token = root / 'token'
        token.write_text('new.valid.token')
        config = {'name': project, 'services': {
            'page': {'image': old_image, 'command': ['sh', '-c', 'if [ "$${REMNAWAVE_API_TOKEN}" = "fail.valid.token" ]; then exit 7; fi; test -f /data/marker || printf keep > /data/marker; exec sleep 600'],
                'environment': {'REMNAWAVE_PANEL_URL': 'https://panel.example.test', 'REMNAWAVE_API_TOKEN': 'old.valid.token', 'KEEP': 'unchanged'},
                'volumes': ['data:/data'], 'healthcheck': {'test': ['CMD', 'test', '-f', '/data/marker'], 'interval': '1s', 'timeout': '1s', 'retries': 3}},
            'proxy': {'image': base_image, 'command': ['sleep', '600']}},
            'volumes': {'data': {}}, 'networks': {'default': {'internal': True}}}
        runtime.write(compose, config)
        item = dict(project=project, service='page', directory=str(page), composeFiles=[str(compose)], tokenUuid=str(uuid.uuid4()))
        runtime.write(state, {'directory': str(panel), 'project': 'panel', 'component': 'panel', 'composeFiles': [], 'subscriptionMigration': item})
        base = migration.compose_base(item)
        try:
            run(*base, 'up', '-d', '--pull', 'never')
            proxy = run(*base, 'ps', '--quiet', 'proxy')
            previous = run(*base, 'ps', '--quiet', 'page')
            migration.upgrade(state, new_image, token, root / 'backups', '1.1.7.56', 'v1.2.90')
            current = runtime.load(state)['subscriptionMigration']
            active = migration.compose_base(current)
            changed = run(*active, 'ps', '--quiet', 'page')
            assert changed != previous
            assert run(*active, 'ps', '--quiet', 'proxy') == proxy
            assert run('docker', 'exec', changed, 'cat', '/data/marker') == 'keep'
            actual = json.loads(run('docker', 'inspect', changed))[0]
            assert runtime.environment(actual)['KEEP'] == 'unchanged'
            assert runtime.environment(actual)['REMNAWAVE_API_TOKEN'] == 'new.valid.token'
            assert not compose.exists() and (page / 'docker-compose.yml').exists()
            canonical_before = (page / 'docker-compose.yml').read_bytes()
            token.write_text('fail.valid.token')
            try:
                migration.upgrade(state, new_image, token, root / 'backups', '1.1.7.56', 'v1.2.90')
            except runtime.ConfigurationError:
                pass
            else:
                raise AssertionError('An exited page must not be reported ready')
            assert (page / 'docker-compose.yml').read_bytes() == canonical_before
            restored = run(*active, 'ps', '--quiet', 'page')
            assert runtime.environment(json.loads(run('docker', 'inspect', restored))[0])['REMNAWAVE_API_TOKEN'] == 'new.valid.token'
            assert run(*active, 'ps', '--quiet', 'proxy') == proxy
            print('PASS: real subscription page upgrade, preserved volume and sibling, canonical layout, failed-ready rollback')
        finally:
            latest = runtime.load(state)['subscriptionMigration']
            files = latest['composeFiles'] if all(Path(value).exists() for value in latest['composeFiles']) else [str(compose)]
            run(*migration.compose_base(latest, files), 'down', '--volumes', '--remove-orphans')
    run('docker', 'image', 'rm', old_image, new_image)


if __name__ == '__main__': main()
