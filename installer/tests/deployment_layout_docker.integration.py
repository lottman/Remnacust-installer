"""Canonical relocation with real bind-mounted PostgreSQL and preserved volumes."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deployment_layout as layout
import runtime

def run(*args):
    return subprocess.run(list(args), text=True, capture_output=True, check=True, timeout=180).stdout

suffix = uuid.uuid4().hex[:12]
project = 'rc-layout-test-' + suffix
image = 'rc-layout-fixture:' + suffix
with tempfile.TemporaryDirectory(prefix='remnacust-layout-docker-') as temporary:
    root = Path(temporary)
    os.environ['REMNACUST_ROOT'] = str(root)
    old = root / 'panel-20261007093515-240659'
    old.mkdir()
    (old / '.env').write_text('APP_SECRET=fixture-preserved\n')
    (old / 'database').mkdir()
    stale_name = 'compose.remnacust-20261010T120000Z-1.json'
    mounted_name = 'compose.remnacust-20261010T120000Z-2.json'
    (old / stale_name).write_text('unused-original-config')
    (old / mounted_name).write_text('mounted-config')
    (old / 'Caddyfile.before-first-vpn').write_text('unused-original-proxy')
    server = "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok' | nc -l -p 3010; done"
    (root / 'Dockerfile').write_text('FROM alpine:3.22\nCMD ' + json.dumps(['sh', '-c', server]) + '\n')
    state = {'schema': 1, 'component': 'panel', 'directory': str(old), 'project': project, 'composeFiles': [str(old / 'compose.json')], 'mainService': 'api', 'applications': ['api'], 'extraServices': ['db'], 'version': '1.1.7.58'}
    with socket.socket() as port_probe:
        port_probe.bind(('127.0.0.1', 0)); port = port_probe.getsockname()[1]
    config = {'name': project, 'services': {
        'api': {'image': image, 'env_file': [str(old / '.env')], 'ports': [f'127.0.0.1:{port}:3010'], 'volumes': ['retained:/state']},
        'db': {'image': 'postgres:18.4', 'environment': {'POSTGRES_PASSWORD': 'layout-fixture-only'}, 'volumes': [str(old / 'database') + ':/var/lib/postgresql'], 'healthcheck': {'test': ['CMD-SHELL', 'pg_isready -U postgres'], 'interval': '1s', 'timeout': '2s', 'retries': 30}},
        'stopped': {'image': image, 'profiles': ['disabled'], 'volumes': [str(old / mounted_name) + ':/fixture:ro']},
    }, 'volumes': {'retained': {}}}
    runtime.write(old / 'compose.json', config)
    runtime.write(root / 'registry/panel.json', state)
    base = layout.compose_base(state)
    def sql(base, statement):
        return run(*base, 'exec', '-T', 'db', 'psql', '-U', 'postgres', '-d', 'postgres', '-At', '-c', statement).strip()
    try:
        run('docker', 'build', '--network=none', '-t', image, str(root))
        run(*base, 'up', '-d', '--no-build', '--pull', 'never', 'api', 'db')
        layout.wait_services(base, ['api', 'db'])
        run(*base, 'up', '--no-start', '--no-deps', '--no-build', '--pull', 'never', 'stopped')
        sql(base, "CREATE TABLE layout_sentinel(value text); INSERT INTO layout_sentinel VALUES ('preserved');")
        run(*base, 'exec', '-T', 'api', 'sh', '-c', 'echo retained > /state/sentinel')
        original_wait = layout.wait_services
        attempts = 0
        def fail_once(*args, **kwargs):
            global attempts
            attempts += 1
            if attempts == 1:
                raise ValueError('CANONICAL_LAYOUT_NOT_READY')
            return original_wait(*args, **kwargs)
        with patch.object(layout, 'wait_services', side_effect=fail_once):
            try:
                layout.normalize(root, 'panel')
                raise AssertionError('readiness failure was ignored')
            except ValueError as error:
                assert str(error) == 'CANONICAL_LAYOUT_NOT_READY'
        assert old.is_dir() and not (root / 'panel').exists()
        assert sql(base, 'SELECT value FROM layout_sentinel') == 'preserved'
        updated = layout.normalize(root, 'panel')
        current = layout.compose_base(updated)
        assert Path(updated['directory']) == root / 'panel'
        assert not old.exists()
        assert (root / 'panel/.env').read_text() == 'APP_SECRET=fixture-preserved\n'
        assert sql(current, 'SELECT value FROM layout_sentinel') == 'preserved'
        assert run(*current, 'exec', '-T', 'api', 'cat', '/state/sentinel').strip() == 'retained'
        stopped = run(*current, 'ps', '--all', '--quiet', 'stopped').strip()
        assert json.loads(run('docker', 'inspect', stopped))[0]['State']['Running'] is False
        archives = list((root / 'backups/panel').glob('legacy-config-*'))
        assert len(archives) == 1
        assert (archives[0] / stale_name).read_text() == 'unused-original-config'
        assert (archives[0] / 'Caddyfile.before-first-vpn').read_text() == 'unused-original-proxy'
        assert (root / 'panel' / mounted_name).read_text() == 'mounted-config'
        before_cleanup = sorted(run(*current, 'ps', '--all', '--quiet').split())
        layout.cleanup_registered(root)
        layout.cleanup_registered(root)
        assert before_cleanup == sorted(run(*current, 'ps', '--all', '--quiet').split())
        assert len(list((root / 'backups/panel').glob('legacy-config-*'))) == 1
        extra = root / 'panel-20261007125352-343161'; extra.mkdir(); (extra / '.env').write_text('retired-data')
        layout.normalize(root, 'panel')
        assert not extra.exists() and (root / 'backups/retired-layout' / extra.name / '.env').read_text() == 'retired-data'
        print('PASS real Docker/PostgreSQL: canonical folder, rollback, credentials, data, stopped service, legacy config archives, protected mounts, idempotent cleanup without restart')
    finally:
        current_state = runtime.load(root / 'registry/panel.json')
        subprocess.run([*layout.compose_base(current_state), '--profile', '*', 'down', '--volumes', '--remove-orphans'], capture_output=True, timeout=180)
        subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)
        if os.geteuid() != 0:
            # PostgreSQL owns its bind data as container uid 999. Return only
            # this disposable fixture to the runner before TemporaryDirectory cleans it.
            assert root.resolve().parent == Path(tempfile.gettempdir()).resolve()
            assert root.name.startswith('remnacust-layout-docker-')
            run('docker', 'run', '--rm', '--network=none', '--mount', f'type=bind,source={root},target=/fixture',
                'alpine:3.22', 'chown', '-R', f'{os.getuid()}:{os.getgid()}', '/fixture')
