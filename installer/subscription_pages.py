#!/usr/bin/env python3
"""Registered subscription-page deployments; never accepts arbitrary Docker commands."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime
from subscription_migration import compose_base, command


def identity(item):
    return hashlib.sha256(('\0'.join(str(item[k]) for k in ('directory', 'project', 'service'))).encode()).hexdigest()[:24]


def records(root):
    items = []
    folder = root / 'registry/subscription-pages'
    if folder.is_symlink():
        raise ValueError('UNSAFE_REGISTRY')
    for path in sorted(folder.glob('*.json')):
        if path.is_symlink():
            raise ValueError('UNSAFE_REGISTRY')
        item = runtime.load(path)
        if path.stem != identity(item):
            raise ValueError('INVALID_PAGE_RECORD')
        items.append(item)
    panel = root / 'registry/panel.json'
    if panel.is_file() and not panel.is_symlink():
        state = runtime.load(panel)
        if state.get('subscriptionPage') and not state.get('uninstalled'):
            items.append({**state, 'service': 'remnawave-subscription-page', 'domain': ', '.join(state.get('subscriptionUrls', [])), 'companion': True})
        if state.get('subscriptionMigration') and not state.get('uninstalled'):
            items.append(state['subscriptionMigration'])
    unique = {}
    for item in items:
        unique.setdefault(identity(item), item)
    if len(unique) > 32:
        raise ValueError('TOO_MANY_PAGES')
    return unique


def selected(root, page):
    if not isinstance(page, str) or not re.fullmatch('[a-f0-9]{24}', page):
        raise ValueError('INVALID_PAGE_ID')
    item = records(root).get(page)
    if item is None:
        raise ValueError('PAGE_NOT_REGISTERED')
    if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', item['service']):
        raise ValueError('INVALID_SERVICE')
    # Paths are root-owned registry values, never browser inputs.
    for value in [item['directory'], *item['composeFiles']]:
        path = Path(value)
        if not path.is_absolute() or path.is_symlink():
            raise ValueError('UNSAFE_PAGE_PATH')
    compose_base(item)
    return item


def inspect(item):
    container = command(compose_base(item), 'ps', '--all', '--quiet', item['service']).strip()
    if not container:
        return None
    if not re.fullmatch('[a-f0-9]{12,64}', container):
        raise ValueError('INVALID_CONTAINER')
    return json.loads(command(['docker'], 'inspect', container))[0]


def listing(root):
    result = []
    for page in records(root):
        item = selected(root, page)
        state = {}
        try:
            current = inspect(item)
            state = (current or {}).get('State', {})
            status = state.get('Health', {}).get('Status') or state.get('Status', 'missing')
            image = (current or {}).get('Config', {}).get('Image', '')
        except (OSError, ValueError, subprocess.SubprocessError):
            status, image = 'unavailable', ''
        result.append({'id': page, 'name': item['project'], 'domain': item.get('domain', ''),
                       'status': status, 'running': bool(state.get('Running')),
                       'image': image[:256], 'companion': bool(item.get('companion'))})
    return result


def ready(item, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = inspect(item)
        state = (current or {}).get('State', {})
        if state.get('Running') and state.get('Health', {}).get('Status') in (None, 'healthy'):
            return
        if state.get('Status') in ('dead', 'exited') or state.get('Health', {}).get('Status') == 'unhealthy':
            break
        time.sleep(2)
    raise ValueError('PAGE_NOT_READY')


def service(root, page, operation):
    if operation not in ('start', 'stop', 'restart'):
        raise ValueError('INVALID_PAGE_OPERATION')
    item = selected(root, page)
    command(compose_base(item), operation, item['service'])
    if operation != 'stop':
        ready(item)


def upgrade(root, page, image, version, release):
    item = selected(root, page)
    base = compose_base(item)
    config = json.loads(command(base, '--profile', '*', 'config', '--no-interpolate', '--no-env-resolution', '--format', 'json'))
    before = copy.deepcopy(config)
    target = config['services'][item['service']]
    target['image'] = image
    target.pop('build', None)
    current = inspect(item)
    current_version = ((current or {}).get('Config', {}).get('Labels') or {}).get('org.opencontainers.image.version', '')
    if re.fullmatch(r'\d+(?:\.\d+){2,3}', current_version) and re.fullmatch(r'\d+(?:\.\d+){2,3}', version):
        if tuple(map(int, current_version.split('.'))) > tuple(map(int, version.split('.'))):
            raise ValueError('PAGE_DOWNGRADE_BLOCKED')
    was_running = bool(current and current.get('State', {}).get('Running'))
    backup = root / 'backups' / ('subscription-page-' + uuid.uuid4().hex)
    backup.mkdir(mode=0o700, parents=True)
    state = {**item, 'component': 'subscription-page', 'mainService': item['service'], 'applications': [item['service']]}
    runtime.write(backup / 'state.before.json', state)
    runtime.write(backup / 'compose.before.json', before)
    runtime.write(backup / 'state.json', state)
    runtime.write(backup / 'candidate.json', config)
    # Validate separately; the registered Compose set is the rollback source.
    command(['docker', 'compose', '--project-name', item['project'], '--project-directory', item['directory'], '-f', str(backup / 'candidate.json')], '--profile', '*', 'config', '--quiet')
    changed = False
    record_path = root / 'registry/subscription-pages' / (page + '.json')
    original_record = runtime.load(record_path) if record_path.exists() else None
    panel_path = root / 'registry/panel.json'
    original_panel = runtime.load(panel_path) if panel_path.exists() else None
    try:
        runtime.commit_compose(backup / 'state.json', backup / 'candidate.json', backup, version, release)
        changed = True
        updated = runtime.load(backup / 'state.json')
        item['composeFiles'] = updated['composeFiles']
        command(compose_base(item), 'up', '--no-deps', '--no-build', '--pull', 'never', *(['-d'] if was_running else ['--no-start']), item['service'])
        if was_running:
            ready(item)
        if item.get('companion'):
            panel = copy.deepcopy(original_panel)
            panel['composeFiles'] = updated['composeFiles']
            runtime.write(panel_path, panel)
        else:
            runtime.write(record_path, item)
            if original_panel and identity(original_panel.get('subscriptionMigration', item)) == page and original_panel.get('subscriptionMigration'):
                panel = copy.deepcopy(original_panel)
                panel['subscriptionMigration']['composeFiles'] = updated['composeFiles']
                runtime.write(panel_path, panel)
        runtime.write_layout(updated, config)
    except Exception:
        if changed:
            runtime.restore_compose(backup)
            if original_panel is not None:
                runtime.write(panel_path, original_panel)
            if original_record is not None:
                runtime.write(record_path, original_record)
            elif record_path.exists():
                record_path.unlink()
            command(base, 'up', '--no-deps', '--no-build', '--pull', 'never', *(['-d'] if was_running else ['--no-start']), item['service'])
        raise


def install(root, directory, project, endpoint, token, number, image, domain='', proxy='existing'):
    directory = Path(directory)
    runtime.project_name(project)
    port = runtime.port(number)
    if not isinstance(endpoint, str) or len(endpoint) > 2048 or '\\' in endpoint or any(ord(c) < 33 or ord(c) == 127 for c in endpoint):
        raise ValueError('INVALID_PANEL_URL')
    if len(token) > 16384:
        raise ValueError('INVALID_TOKEN')
    network = None
    if endpoint == 'auto':
        state = runtime.load(root / 'registry/panel.json')
        container = inspect({**state, 'service': state['mainService']})
        if not container or not container.get('State', {}).get('Running'):
            raise ValueError('LOCAL_PANEL_UNAVAILABLE')
        networks = container.get('NetworkSettings', {}).get('Networks', {})
        network = next((name for name in networks if name not in ('host', 'bridge', 'none')), None)
        name = container['Name'].lstrip('/')
        if not network or not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name):
            raise ValueError('LOCAL_PANEL_NETWORK_UNAVAILABLE')
        endpoint = 'http://' + name + ':' + str(runtime.port(runtime.environment(container).get('APP_PORT', '3000')))
    url = urlsplit(endpoint)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('', '/'):
        raise ValueError('INVALID_PANEL_URL')
    if url.scheme != 'https' and not network:
        raise ValueError('HTTPS_PANEL_REQUIRED')
    runtime.subscription_env(token)
    if not directory.is_absolute() or directory.is_symlink() or directory == Path(directory.anchor) or (directory.exists() and any(directory.iterdir())):
        raise ValueError('PAGE_DIRECTORY_NOT_EMPTY')
    if proxy not in ('existing', 'caddy'):
        raise ValueError('INVALID_PROXY')
    if domain:
        domain = runtime.domain(domain)
    if proxy == 'caddy' and not domain:
        raise ValueError('PAGE_DOMAIN_REQUIRED')
    if command(['docker'], 'ps', '--all', '--quiet', '--filter', 'label=com.docker.compose.project=' + project).strip() or command(['docker', 'volume'], 'ls', '--quiet', '--filter', 'label=com.docker.compose.project=' + project).strip():
        raise ValueError('COMPOSE_PROJECT_EXISTS')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    environment = runtime.subscription_env(token).replace('REMNAWAVE_PANEL_URL=http://remnawave:3000', 'REMNAWAVE_PANEL_URL=' + endpoint.rstrip('/'))
    runtime.write(directory / '.env', environment)
    page = {'image': image, 'restart': 'unless-stopped', 'env_file': [str(directory / '.env')],
            'ports': [f'127.0.0.1:{port}:3010'],
            'labels': {'io.remnacust.service-role': 'subscription-page'},
            'logging': {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '3'}},
            'healthcheck': {'test': ['CMD', 'node', '-e', 'fetch("http://127.0.0.1:3010/internal/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'], 'interval': '5s', 'timeout': '5s', 'retries': 12, 'start_period': '20s'}}
    config = {'name': project, 'services': {'subscription-page': page}}
    if network:
        page['networks'] = ['default', 'panel']
        config['networks'] = {'default': {}, 'panel': {'external': True, 'name': network}}
    if proxy == 'caddy':
        runtime.write(directory / 'Caddyfile', domain + ' {\n    reverse_proxy subscription-page:3010\n}\n')
        config['services']['caddy'] = {'image': 'caddy:2-alpine', 'restart': 'unless-stopped', 'ports': ['80:80', '443:443', '443:443/udp'], 'volumes': [str(directory / 'Caddyfile') + ':/etc/caddy/Caddyfile:ro', 'caddy-data:/data', 'caddy-config:/config']}
        config['volumes'] = {'caddy-data': {}, 'caddy-config': {}}
    runtime.write(directory / 'docker-compose.yml', config)
    item = {'directory': str(directory), 'project': project, 'service': 'subscription-page',
            'composeFiles': [str(directory / 'docker-compose.yml')], 'domain': domain}
    runtime.write(root / 'registry/subscription-pages' / (identity(item) + '.json'), item)
    command(compose_base(item), 'config', '--quiet')
    command(compose_base(item), 'up', '-d', '--no-build', '--pull', 'never')
    ready(item)
    runtime.write_layout({**item, 'component': 'subscription-page'}, config)
    return identity(item)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['install', 'upgrade', 'list', 'start', 'stop', 'restart'])
    parser.add_argument('--root', type=Path, required=True)
    for name in ('page-id', 'directory', 'project', 'panel-url', 'token-file', 'port', 'image', 'domain', 'proxy', 'version', 'release'):
        parser.add_argument('--' + name)
    args = parser.parse_args()
    if args.operation == 'list':
        print(json.dumps(listing(args.root), ensure_ascii=False))
    elif args.operation == 'install':
        print(install(args.root, args.directory, args.project, args.panel_url, Path(args.token_file).read_text().strip(), args.port or '3010', args.image, args.domain or '', args.proxy or 'existing'))
    elif args.operation == 'upgrade':
        upgrade(args.root, args.page_id, args.image, args.version, args.release)
    else:
        service(args.root, args.page_id, args.operation)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError):
        raise SystemExit('Операция страницы подписки не завершена. Проверьте её журнал и конфигурацию; секретный вывод скрыт.')
