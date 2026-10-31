"""Panel connection validation and isolated subscription-page environment edits."""
import base64
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit

import runtime


def read_token(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 16384:
            raise ValueError('INVALID_TOKEN_FILE')
        if os.name != 'nt' and (info.st_uid not in {0, os.geteuid()} or info.st_mode & 0o077):
            raise ValueError('TOKEN_FILE_MUST_BE_PRIVATE')
        token = stream.read(16385).decode('utf-8').strip()
    validate_token(token)
    return token


def validate_token(token):
    if not isinstance(token, str) or len(token) > 16384:
        raise ValueError('INVALID_TOKEN')
    runtime.subscription_env(token)


def resolve(root, endpoint, inspect):
    if not isinstance(endpoint, str) or not endpoint or len(endpoint) > 2048 or '\\' in endpoint or any(ord(c) < 33 or ord(c) == 127 for c in endpoint):
        raise ValueError('INVALID_PANEL_URL')
    network = None
    if endpoint == 'auto':
        state = runtime.load(root / 'registry/panel.json')
        container = inspect({**state, 'service': state['mainService']})
        if not container or not container.get('State', {}).get('Running'):
            raise ValueError('LOCAL_PANEL_UNAVAILABLE')
        networks = container.get('NetworkSettings', {}).get('Networks') or {}
        network = next((name for name in networks if name not in ('host', 'bridge', 'none')), None)
        name = container.get('Name', '').lstrip('/')
        if not network or not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name):
            raise ValueError('LOCAL_PANEL_NETWORK_UNAVAILABLE')
        endpoint = 'http://' + name + ':' + str(runtime.port(runtime.environment(container).get('APP_PORT', '3000')))
    else:
        endpoint = endpoint if '://' in endpoint else 'https://' + endpoint
    url = urlsplit(endpoint)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('', '/') or url.port == 0:
        raise ValueError('INVALID_PANEL_URL')
    if url.scheme != 'https' and not network:
        raise ValueError('HTTPS_PANEL_REQUIRED')
    return endpoint.rstrip('/'), network


PROBE = r"""const headers = {Authorization: 'Bearer ' + process.env.REMNAWAVE_API_TOKEN};
if (process.env.REMNAWAVE_PANEL_URL.startsWith('http://')) {
 headers['X-Forwarded-For'] = '127.0.0.1'; headers['X-Forwarded-Proto'] = 'https';
}
async function get(path) {
 const abort = new AbortController(), timer = setTimeout(() => abort.abort(), 8000);
 try {
  const response = await fetch(process.env.REMNAWAVE_PANEL_URL + path, {headers, redirect:'error', signal:abort.signal});
  if (!response.ok) throw Error('panel-access');
  let size=0, chunks=[];
  for await (const chunk of response.body) {size+=chunk.length;if(size>4*1024*1024){abort.abort();throw Error('panel-response');}chunks.push(Buffer.from(chunk));}
  const value=JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!value || typeof value!=='object' || !value.response || typeof value.response!=='object') throw Error('panel-response');
  return value.response;
 } finally {clearTimeout(timer);}
}
(async()=>{
 const metadata=await get('/api/system/metadata'); if(typeof metadata.version!=='string')throw Error('panel-version');
 const configs=await get('/api/subscription-page-configs');
 const rows=Array.isArray(configs)?configs:configs.configs;
 if(!Array.isArray(rows))throw Error('panel-configs');
 if(rows[0]?.uuid)await get('/api/subscription-page-configs/'+encodeURIComponent(rows[0].uuid));
})().catch(()=>{console.error('Проверка панели и прав токена не пройдена. Проверьте HTTPS, доступность и права страницы подписки.');process.exitCode=1;});
"""


def probe(image, endpoint, token, network, current, command):
    validate_token(token)
    if not isinstance(image, str) or not image:
        raise ValueError('PAGE_IMAGE_UNAVAILABLE')
    with tempfile.TemporaryDirectory(prefix='remnacust-page-probe-') as folder:
        env = Path(folder) / 'connection.env'
        runtime.write(env, 'REMNAWAVE_PANEL_URL=' + endpoint + '\nREMNAWAVE_API_TOKEN=' + token + '\n')
        networks = (current or {}).get('NetworkSettings', {}).get('Networks') or {}
        try:
            if (current or {}).get('State', {}).get('Running') and (not network or network in networks) and current.get('Id'):
                command(['docker'], 'exec', '--env-file', str(env), current['Id'], 'node', '-e', PROBE)
            else:
                chosen = network or next(iter(networks), 'bridge')
                command(['docker'], 'run', '--rm', '--pull', 'never', '--network', chosen,
                        '--env-file', str(env), '--entrypoint', 'node', image, '-e', PROBE)
        except (OSError, ValueError, subprocess.SubprocessError):
            raise ValueError('PANEL_ACCESS_FAILED') from None


def edit(config, item, endpoint, token, network):
    """Return deferred private env-file edits; shared env files stay untouched."""
    import management
    target = config['services'][item['service']]
    values = {'REMNAWAVE_PANEL_URL': endpoint, 'REMNAWAVE_API_TOKEN': token}
    paths = management.env_paths(target, item['directory'])
    shared = any(path in management.env_paths(other, item['directory'])
                 for name, other in config['services'].items() if name != item['service'] for path in paths)
    plan = {'files': {}}
    if shared:
        target['environment'] = {**runtime.compose_environment(target.get('environment')), **values}
    else:
        management.configure_environment(plan, {'after': config, 'item': item}, [item['service']], values)
    if network:
        if target.get('network_mode'):
            raise ValueError('PAGE_NETWORK_MODE_UNSUPPORTED')
        networks = config.setdefault('networks', {})
        key = next((name for name, value in networks.items() if isinstance(value, dict) and value.get('name') == network), 'remnacust-panel')
        if key in networks and (not isinstance(networks[key], dict) or networks[key].get('name') != network):
            raise ValueError('PAGE_NETWORK_CONFLICT')
        networks.setdefault(key, {'external': True, 'name': network})
        attached = target.get('networks', ['default'])
        if isinstance(attached, dict):
            attached.setdefault(key, {})
        else:
            attached = list(dict.fromkeys([*attached, key]))
        target['networks'] = attached
    return plan['files']


def write_edits(files, restore=False):
    for name, value in files.items():
        text = base64.b64decode(value['before']).decode('utf-8') if restore else value['after']
        runtime.write(name, text, value['mode'] if restore else 0o600)
