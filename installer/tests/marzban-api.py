"""Real destination API, disposable source HTTP fixture. No production credentials."""
import argparse
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import marzban

parser = argparse.ArgumentParser()
parser.add_argument('container'); parser.add_argument('url')
args = parser.parse_args()
created = subprocess.check_output(['docker', 'exec', args.container, 'node', '-e', '''
const {PrismaClient}=require('@prisma/client'),jwt=require('jsonwebtoken');const p=new PrismaClient();
(async()=>{const squad=await p.internalSquads.create({data:{name:'installer-migration-squad'}});const t=await p.apiTokens.create({data:{name:'installer-fixture',expireAt:new Date(Date.now()+3600000),scopes:['*']}});console.log(JSON.stringify({squad:squad.uuid,token:jwt.sign({uuid:t.uuid,username:null,role:'API'},process.env.APP_SECRET,{expiresIn:'1h'})}));})().finally(()=>p.$disconnect()).catch(()=>process.exitCode=1);
'''], text=True)
credentials = json.loads(created)
user = {'username': 'marzban_fixture', 'status': 'active', 'expire': 1800000000, 'created_at': '2026-01-01T12:00:00',
        'data_limit': 1000, 'used_traffic': 400, 'data_limit_reset_strategy': 'no_reset',
        'proxies': {'vless': {'id': 'cccccccc-cccc-4ccc-cccc-cccccccccccc'}, 'trojan': {'password': 'fixture-password'}}, 'note': 'fixture'}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"access_token":"fixture"}')
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps({'users': [user], 'total': 1}).encode())
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
os.environ.update(MARZBAN_USERNAME='fixture', MARZBAN_PASSWORD='fixture', REMNACUST_API_TOKEN=credentials['token'])
try:
    with tempfile.TemporaryDirectory() as t:
        base = dict(source_url='http://127.0.0.1:'+str(server.server_port), destination_url=args.url, internal_squad=credentials['squad'],
                    batch_size=100, quota_mode='remaining', preserve_subhash=False, dry_run=True, yes=True)
        def operation(name, **changes):
            return argparse.Namespace(**{**base, 'output': str(Path(t)/name), **changes})
        marzban.run(operation('preview'))
        destination = marzban.Api(args.url, credentials['token'])
        assert marzban.destination_user(destination, user['username']) is None
        marzban.run(operation('import', dry_run=False))
        result = json.loads((Path(t)/'import/result.json').read_text())
        assert result['created'] == ['marzban_fixture'] and not result['failed']
        current = marzban.destination_user(destination, user['username'])
        assert current['trafficLimitBytes'] == 600 and current['trojanPassword'] == 'fixture-password'
        marzban.run(operation('resume', dry_run=False))
        result = json.loads((Path(t)/'resume/result.json').read_text())
        assert result['identical'] == ['marzban_fixture'] and not result['created']
        user['proxies']['trojan']['password'] = 'changed-password'
        try: marzban.run(operation('conflict', dry_run=False))
        except marzban.MigrationError: pass
        else: raise AssertionError('Conflict accepted')
        assert marzban.destination_user(destination, user['username'])['trojanPassword'] == 'fixture-password'
        print('PASS actual API: Marzban preview, create, key/quota verification, resume and conflict refusal')
finally:
    server.shutdown(); server.server_close()
