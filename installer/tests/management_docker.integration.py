"""One-off local HTTP processes: real Compose recreation and rollback, no VPN or ACME."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import management
import runtime
from subscription_migration import command, compose_base

project = 'management-' + uuid.uuid4().hex[:12]
with tempfile.TemporaryDirectory(prefix='remnacust-management-') as folder:
    root = Path(folder)
    os.environ['REMNACUST_ROOT'] = folder
    directory = root / 'panel'; directory.mkdir()
    runtime.write(directory / '.env', 'APP_SECRET=unchanged-fixture-secret\nFRONT_END_DOMAIN=https://old.example.test\nPANEL_DOMAIN=old.example.test\nSUB_PUBLIC_DOMAIN=old.example.test/api/sub\n')
    runtime.write(directory / 'Caddyfile', 'http://old.example.test {\n reverse_proxy api:8080\n}\n')
    app = {'image': 'python:3.12-alpine', 'command': ['python', '-m', 'http.server', '8080'], 'env_file': [str(directory / '.env')],
           'healthcheck': {'test': ['CMD', 'python', '-c', 'import urllib.request;urllib.request.urlopen("http://127.0.0.1:8080")'], 'interval': '1s', 'timeout': '2s', 'retries': 15}}
    if os.environ.get('REMNACUST_MANAGEMENT_NODE_IMAGE'):
        app.update(image=os.environ['REMNACUST_MANAGEMENT_NODE_IMAGE'], command=['node', '-e', 'require("node:http").createServer((req,res)=>res.end("ok")).listen(8080)'],
                   healthcheck={'test': ['CMD', 'node', '-e', 'fetch("http://127.0.0.1:8080").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'], 'interval': '1s', 'timeout': '2s', 'retries': 15})
    config = {'services': {'api': app, 'worker': {**app, 'healthcheck': {'disable': True}},
                          'database': {'image': 'python:3.12-alpine', 'command': ['sleep', '600']},
                          'caddy': {'image': os.environ.get('REMNACUST_MANAGEMENT_CADDY_IMAGE', 'caddy:2-alpine'), 'volumes': [str(directory / 'Caddyfile') + ':/etc/caddy/Caddyfile:ro']}}}
    if os.environ.get('REMNACUST_MANAGEMENT_NODE_IMAGE'):
        config['services']['database']['image'] = os.environ['REMNACUST_MANAGEMENT_NODE_IMAGE']
    runtime.write(directory / 'docker-compose.yml', config)
    state = {'component': 'panel', 'directory': str(directory), 'project': project, 'mainService': 'api',
             'applications': ['api', 'worker'], 'extraServices': ['caddy'], 'composeFiles': [str(directory / 'docker-compose.yml')],
             'panelDomain': 'old.example.test', 'subscriptionUrls': ['https://old.example.test/api/sub'], 'version': '1.1.7.61'}
    runtime.write(root / 'registry/panel.json', state)
    base = compose_base(state)
    try:
        command(base, 'up', '-d', '--no-build', '--pull', 'never', 'api', 'database', 'caddy')
        command(base, 'create', '--no-build', '--pull', 'never', 'worker')
        database_id = command(base, 'ps', '--all', '--quiet', 'database').strip()
        plan = management.prepare(root, 'panel', 'new.example.test')
        management.apply(plan)
        api_id = command(base, 'ps', '--all', '--quiet', 'api').strip()
        api = json.loads(command(['docker'], 'inspect', api_id))[0]
        values = runtime.environment(api)
        assert values['APP_SECRET'] == 'unchanged-fixture-secret'
        assert values['FRONT_END_DOMAIN'] == 'https://new.example.test'
        assert command(base, 'ps', '--all', '--quiet', 'database').strip() == database_id
        worker_id = command(base, 'ps', '--all', '--quiet', 'worker').strip()
        assert not json.loads(command(['docker'], 'inspect', worker_id))[0]['State']['Running']
        caddy_id = command(base, 'ps', '--all', '--quiet', 'caddy').strip()
        assert 'new.example.test' in command(['docker', 'exec', caddy_id], 'cat', '/etc/caddy/Caddyfile')
        management.rollback(plan)
        api_id = command(base, 'ps', '--all', '--quiet', 'api').strip()
        api = json.loads(command(['docker'], 'inspect', api_id))[0]
        assert runtime.environment(api)['FRONT_END_DOMAIN'] == 'https://old.example.test'
        assert command(base, 'ps', '--all', '--quiet', 'database').strip() == database_id
        assert runtime.load(root / 'registry/panel.json')['panelDomain'] == 'old.example.test'
        print('PASS real Compose domain change and rollback preserve secret, stopped worker, database and proxy mounts')
    finally:
        subprocess.run([*base, 'down', '--volumes', '--remove-orphans'], capture_output=True, timeout=90, check=True)
