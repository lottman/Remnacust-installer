"""Real local panel authentication and isolated page reconfiguration; no public ports."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime
import subscription_pages as pages

nonce = uuid.uuid4().hex[:12]
panel_project, page_project = 'rc-connection-panel-' + nonce, 'rc-connection-page-' + nonce
image = 'rc-connection-fixture:' + nonce
def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True, timeout=90).stdout.strip()

with tempfile.TemporaryDirectory(prefix='rc-connection-') as folder:
    root = Path(folder); os.environ['REMNACUST_ROOT'] = str(root)
    server = r"""require('http').createServer((req,res)=>{
      if(req.url==='/internal/health'){res.end('ok');return;}
      if(!['Bearer new.valid.token','Bearer next.valid.token'].includes(req.headers.authorization)){res.writeHead(403);res.end();return;}
      res.setHeader('Content-Type','application/json');res.end(JSON.stringify({response:req.url.endsWith('metadata')?{version:'1.1.7.71'}:{configs:[]}}));
    }).listen(Number(process.env.APP_PORT)||3010,'0.0.0.0');"""
    (root / 'server.js').write_text(server)
    (root / 'Dockerfile').write_text('FROM node:24.22.1-trixie-slim\nCOPY server.js /server.js\nCMD ["node","/server.js"]\n')
    panel = root / 'panel'; panel.mkdir()
    source = panel / 'docker-compose.yml'
    runtime.write(source, {'services': {'api': {'image': image, 'environment': {'APP_PORT': '3000'}}}})
    panel_state = {'component': 'panel', 'mainService': 'api', 'directory': str(panel), 'project': panel_project, 'composeFiles': [str(source)]}
    runtime.write(root / 'registry/panel.json', panel_state)
    page = None
    try:
        docker('build', '--network=none', '-t', image, str(root))
        base = ['compose', '--project-name', panel_project, '-f', str(source)]
        docker(*base, 'up', '-d', '--pull', 'never')
        panel_id = docker(*base, 'ps', '-q', 'api')
        page = pages.install(root, root / 'page', page_project, 'auto', 'new.valid.token', 3019, image, 'subscription.example.test')
        item = pages.selected(root, page)
        before = (root / 'page/.env').read_bytes()
        original_id = pages.inspect(item)['Id']
        try:
            pages.configure(root, page, 'auto', 'bad.valid.token')
            raise AssertionError('Bad token was accepted')
        except ValueError:
            pass
        assert (root / 'page/.env').read_bytes() == before
        assert pages.inspect(item)['Id'] == original_id
        pages.configure(root, page, 'auto', 'next.valid.token')
        assert runtime.environment(pages.inspect(item))['REMNAWAVE_API_TOKEN'] == 'next.valid.token'
        assert docker(*base, 'ps', '-q', 'api') == panel_id
        before = (root / 'page/.env').read_bytes()
        with patch.object(pages, 'ready', side_effect=ValueError('fixture readiness failure')):
            try:
                pages.configure(root, page, 'auto', 'new.valid.token')
                raise AssertionError('Failed readiness passed')
            except ValueError:
                pass
        assert (root / 'page/.env').read_bytes() == before
        assert runtime.environment(pages.inspect(item))['REMNAWAVE_API_TOKEN'] == 'next.valid.token'
        pages.service(root, page, 'stop')
        pages.configure(root, page, 'auto', 'new.valid.token')
        assert not pages.inspect(item)['State']['Running']
        assert docker(*base, 'ps', '-q', 'api') == panel_id
        print('PASS real Docker panel auth, failed-token preservation, selected-page update, readiness rollback and retained stopped state')
    finally:
        for project, file in [(page_project, root / 'page/docker-compose.yml'), (panel_project, source)]:
            if file.is_file():
                subprocess.run(['docker', 'compose', '--project-name', project, '-f', str(file), 'down', '--remove-orphans'], capture_output=True, timeout=90)
        subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)
