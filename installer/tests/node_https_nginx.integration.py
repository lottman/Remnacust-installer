from pathlib import Path
import json
import os
import runpy
import sys
import tempfile

os.environ.setdefault('IMAGE', 'nginx:1.28-alpine')
source = Path(__file__).resolve().parents[2]
module = runpy.run_path(str(source / 'installer/tests/node_site_nginx.integration.py'), run_name='node_https_fixture')
if os.geteuid() != 0:
    raise SystemExit('Run this isolated Docker test as root')
with tempfile.TemporaryDirectory(prefix='rc-public-https-') as temporary:
    fixture = module['Fixture'](Path(temporary))
    try:
        fixture.site.install_site(fixture.deploy, module['HOSTNAME'])
        for port in (443, 4433):
            (fixture.root / 'server.conf').write_text(fixture.runtime.nginx_config(module['HOSTNAME'], port))
            identifier = fixture.start()
            connection = fixture.ready()
            fixture.request(connection, '/')
            connection.close()
            inspected = json.loads(fixture.command('docker', 'inspect', identifier))[0]
            assert inspected['HostConfig']['NetworkMode'] == 'none'
            assert not inspected['HostConfig'].get('PortBindings')
            pid = str(inspected['State']['Pid'])
            content = fixture.command('nsenter', '-t', pid, '-n', 'curl', '--fail', '--silent', '--show-error', '--noproxy', '*', '--max-time', '5', '--cacert', str(fixture.certs / 'fullchain.pem'), '--resolve', f'{module["HOSTNAME"]}:{port}:127.0.0.1', f'https://{module["HOSTNAME"]}:{port}/')
            assert content.encode() == (fixture.deploy / 'www/index.html').read_bytes().strip()
            state = json.dumps({'directory': str(fixture.root), 'nodeDomain': module['HOSTNAME'], 'nodeSiteMode': 'standalone', 'nodeSitePort': port})
            fixture.command('nsenter', '-t', pid, '-n', sys.executable, '-c', 'import sys,json;sys.path.insert(0,sys.argv[1]);import runtime;runtime.wait_node_https(json.loads(sys.argv[2]))', str(source / 'installer'), state)
            fixture.stop(identifier)
        print('PASS standalone HTTPS on 443 and 4433 with verified hostname/CA, retained Unix PROXY path, no host ports/network')
    finally:
        fixture.cleanup()
