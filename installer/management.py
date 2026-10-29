"""Transactional domain changes for registered deployments, without changing credentials."""
import argparse
import base64
import copy
import json
import os
from pathlib import Path
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit, urlunsplit
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime
import subscription_pages as pages
import tls
from subscription_migration import command, compose_base


class ManagementError(ValueError):
    """A diagnostic that is safe to show without printing configuration values."""


def safe_file(value, optional=False):
    path = Path(value)
    if not path.is_absolute() or path == Path(path.anchor) or path.is_symlink():
        raise ManagementError('Небезопасный путь настройки')
    if not optional and not path.is_file():
        raise ManagementError('Файл настройки отсутствует: ' + str(path))
    if path.exists() and (not path.is_file() or path.stat().st_size > 8 * 1024**2):
        raise ManagementError('Файл настройки слишком большой или имеет неверный тип')
    return path


def deployment(root, component, page_id=None):
    if component == 'subscription-page':
        item = pages.selected(root, page_id)
        if item.get('companion'):
            return root / 'registry/panel.json', runtime.load(root / 'registry/panel.json'), item
        path = root / 'registry/subscription-pages' / (page_id + '.json')
        if path.exists():
            return path, runtime.load(path), item
        panel = root / 'registry/panel.json'
        return panel, runtime.load(panel), item
    if component not in ('panel', 'node'):
        raise ManagementError('Выберите panel, node или subscription-page')
    path = safe_file(root / 'registry' / (component + '.json'))
    state = runtime.load(path)
    if state.get('uninstalled') or state.get('component') != component:
        raise ManagementError('Компонент удалён или не зарегистрирован')
    return path, state, {**state, 'service': state['mainService']}


def replace_host(value, before, after):
    if not isinstance(value, str):
        return value
    url = urlsplit(value if '://' in value else 'https://' + value)
    if url.hostname != before:
        return value
    if url.username or url.password or url.port:
        raise ManagementError('Адрес с credentials или нестандартным портом требует ручной настройки')
    result = urlunsplit((url.scheme, after, url.path, url.query, url.fragment))
    return result if '://' in value else result.split('://', 1)[1]


def update_env(text, values):
    for key, value in values.items():
        pattern = r'^(?:export[ \t]+)?' + re.escape(key) + r'[ \t]*=.*$'
        if re.search(pattern, text, re.M):
            text = re.sub(pattern, lambda _: key + '=' + value, text, flags=re.M)
        else:
            text = text.rstrip('\n') + '\n' + key + '=' + value + '\n'
    return text


def proxy_text(text, before, after, kind='caddy'):
    pattern = r'(?<![A-Za-z0-9_.-])' + re.escape(before) + r'(?![A-Za-z0-9_.-])'
    changed = False
    def replace(value):
        nonlocal changed
        result, count = re.subn(pattern, lambda _: after, value, flags=re.I)
        changed = changed or count > 0
        return result
    if kind == 'nginx':
        result = re.sub(r'(?m)^(\s*server_name\s+)([^;]+)(;)',
                        lambda match: match[1] + replace(match[2]) + match[3], text)
    else:
        depth = 0
        lines = []
        for line in text.splitlines(keepends=True):
            content = line.split('#', 1)[0]
            if depth == 0 and '{' in content and content.split('{', 1)[0].strip():
                prefix, suffix = line.split('{', 1)
                line = replace(prefix) + '{' + suffix
            depth += content.count('{') - content.count('}')
            lines.append(line)
        result = ''.join(lines)
    if not changed:
        raise ManagementError('Старый домен не найден в управляемом reverse proxy; изменения не применены')
    return result


def snapshot(plan, path):
    path = safe_file(path, optional=True)
    key = str(path)
    if key not in plan['files']:
        data = path.read_bytes() if path.exists() else None
        plan['files'][key] = {'before': base64.b64encode(data).decode() if data is not None else None,
                              'mode': path.stat().st_mode & 0o777 if data is not None else 0o600}
    return key


def edit_file(plan, path, text):
    key = snapshot(plan, path)
    plan['files'][key]['after'] = text


def env_paths(service, directory):
    values = service.get('env_file') or []
    if not isinstance(values, list):
        values = [values]
    return [safe_file(Path(directory) / (value['path'] if isinstance(value, dict) else value)) for value in values]


def configure_environment(plan, unit, names, values):
    for name in names:
        service = unit['after']['services'][name]
        inline = runtime.compose_environment(service.get('environment'))
        paths = env_paths(service, unit['item']['directory'])
        for key, value in values.items():
            if key in inline or not paths:
                inline[key] = value
            if paths:
                # The last env_file is authoritative for a new key; update existing copies too.
                for path in paths:
                    original = plan['files'].get(str(path), {}).get('after', path.read_text())
                    if path == paths[-1] or re.search(r'^(?:export[ \t]+)?' + key + r'[ \t]*=', original, re.M):
                        edit_file(plan, path, update_env(original, {key: value}))
        if inline or service.get('environment') is not None:
            service['environment'] = inline


def candidate_base(item, candidate):
    return ['docker', 'compose', '--project-name', runtime.project_name(item['project']),
            '--project-directory', item['directory'], '-f', str(candidate)]


def add_unit(plan, item, state):
    base = compose_base(item)
    config = json.loads(command(base, '--profile', '*', 'config', '--no-interpolate', '--no-env-resolution', '--format', 'json'))
    names = list(dict.fromkeys([item['service'], *state.get('applications', []), *state.get('extraServices', [])]))
    names = [name for name in names if name in config['services']]
    statuses = {}
    for name in names:
        current = pages.inspect({**item, 'service': name})
        statuses[name] = bool(current and current.get('State', {}).get('Running'))
    unit = {'item': item, 'state': copy.deepcopy(state), 'before': config, 'after': copy.deepcopy(config),
            'running': statuses, 'services': names}
    plan['units'].append(unit)
    for path in item['composeFiles']:
        snapshot(plan, Path(item['directory']) / path)
    snapshot(plan, Path(item['directory']) / 'docker-compose.yml')
    for path in (Path(item['directory']) / 'FILES.txt', Path(plan['root']) / 'FILES.txt'):
        if not path.is_symlink():
            snapshot(plan, path)
    return unit


def prepare(root, component, hostname, page_id=None):
    hostname = runtime.domain(hostname)
    record, state, item = deployment(root, component, page_id)
    shared = component == 'subscription-page' and (item.get('companion') or (
        state.get('component') == 'panel' and state.get('directory') == item['directory'] and state.get('project') == item['project']))
    if shared:
        item = {**item, 'companion': True}
    old = (urlsplit('https://' + item.get('domain', '')).hostname if component == 'subscription-page' and not item.get('companion')
           else urlsplit(state.get('subscriptionUrls', [''])[0]).hostname if component == 'subscription-page'
           else state.get('panelDomain' if component == 'panel' else 'nodeDomain'))
    if not old and component == 'subscription-page' and state.get('subscriptionUrls'):
        old = urlsplit(state['subscriptionUrls'][0]).hostname
    if not old and component != 'node':
        raise ManagementError('Исходный домен не зарегистрирован. Сначала перенесите или обновите установку')
    old = runtime.domain(old) if old else ''
    if hostname == old:
        raise ManagementError('Этот домен уже используется')
    backup = root / 'backups' / ('domain-' + component + '-' + uuid.uuid4().hex)
    backup.mkdir(mode=0o700, parents=True)
    plan = {'root': str(root), 'component': component, 'old': old, 'domain': hostname,
            'files': {}, 'records': {}, 'units': [], 'phase': 'prepared', 'backup': str(backup)}
    effective = state if component != 'subscription-page' or item.get('companion') else {
        **item, 'component': 'subscription-page', 'mainService': item['service'], 'applications': [item['service']],
        'extraServices': ['caddy'] if (Path(item['directory']) / 'Caddyfile').exists() else []}
    unit = add_unit(plan, item, effective)
    directory = Path(item['directory'])
    proxy = 'node-nginx' if component == 'node' else 'caddy'
    if component == 'node' and proxy not in unit['after']['services']:
        generated, _ = runtime.fresh('node', directory, item['project'], unit['after']['services'][item['service']]['image'], node_domain=hostname)
        unit['after']['services'][proxy] = generated['services'][proxy]
        main = unit['after']['services'][item['service']]
        mounts = main.setdefault('volumes', [])
        for mount in mounts:
            target = mount.get('target') if isinstance(mount, dict) else mount.split(':')[1] if ':' in mount else ''
            if target == '/var/lib/remnacust/tls':
                raise ManagementError('У ноды уже есть собственное подключение TLS. Настройте его домен вручную')
        mounts.append({'type': 'bind', 'source': str(directory / 'certs'), 'target': '/var/lib/remnacust/tls', 'read_only': True})
        unit['addedProxy'] = True
        unit['state']['extraServices'] = [*state.get('extraServices', []), proxy]
    if proxy not in unit['after']['services']:
        raise ManagementError('Reverse proxy не управляется этим установщиком. Сначала настройте его домен и сертификат отдельно')
    if proxy not in unit['services']:
        unit['services'].append(proxy)
        current = pages.inspect({**item, 'service': proxy})
        unit['running'][proxy] = bool(current and current.get('State', {}).get('Running')) if not unit.get('addedProxy') else unit['running'].get(item['service'], False)
    unit['proxy'] = proxy
    proxy_path = directory / ('nginx.conf' if component == 'node' else 'Caddyfile')
    edit_file(plan, proxy_path, runtime.nginx_config(hostname) if unit.get('addedProxy') else proxy_text(safe_file(proxy_path).read_text(), old, hostname, 'nginx' if component == 'node' else 'caddy'))
    updated = copy.deepcopy(state)
    if component == 'panel':
        updated['panelDomain'] = hostname
        values = {'FRONT_END_DOMAIN': 'https://' + hostname, 'PANEL_DOMAIN': hostname}
        urls = [replace_host(url, old, hostname) for url in state.get('subscriptionUrls', [])]
        if urls:
            updated['subscriptionUrls'] = urls
            if urls != state.get('subscriptionUrls'):
                values['SUB_PUBLIC_DOMAIN'] = urls[0].split('://', 1)[1]
        configure_environment(plan, unit, [n for n in state['applications'] if n != 'remnawave-subscription-page'], values)
    elif component == 'node':
        updated['nodeDomain'] = hostname
        updated['extraServices'] = unit['state'].get('extraServices', [])
    elif item.get('companion'):
        urls = [replace_host(url, old, hostname) for url in state['subscriptionUrls']]
        updated['subscriptionUrls'] = urls
        configure_environment(plan, unit, [n for n in state['applications'] if n != 'remnawave-subscription-page'], {'SUB_PUBLIC_DOMAIN': urls[0].split('://', 1)[1]})
        if updated.get('subscriptionMigration'):
            updated['subscriptionMigration']['domain'] = hostname
    elif record.name == 'panel.json':
        updated['subscriptionMigration']['domain'] = hostname
        updated['subscriptionUrls'] = [replace_host(url, old, hostname) for url in state.get('subscriptionUrls', [])]
    else:
        updated['domain'] = hostname
    plan['records'][str(record)] = updated
    snapshot(plan, record)
    unit['state'].update({key: updated[key] for key in ('panelDomain', 'nodeDomain', 'subscriptionUrls') if key in updated})
    managed_component = 'panel' if item.get('companion') else component
    method = (state.get('tls', {}).get('method', 'http' if component == 'node' else 'auto')
              if component != 'subscription-page' or item.get('companion') else 'auto')
    if method not in ('auto', 'http', 'existing', 'cloudflare', 'gcore') or (component == 'node' and method == 'auto'):
        raise ManagementError('Неизвестный способ TLS в реестре; конфигурация не изменена')
    plan.update(proxy=proxy, directory=str(directory), method=method, project=item['project'],
                certificateDomain=(updated.get('panelDomain') if item.get('companion') else hostname),
                certificateSubscriptions=','.join(updated.get('subscriptionUrls', [])) if managed_component == 'panel' and state.get('subscriptionPage') else '',
                tlsComponent=managed_component, tlsState=updated)
    if shared and updated.get('subscriptionUrls'):
        plan['certificateSubscriptions'] = ','.join(updated['subscriptionUrls'])
        plan['tlsState'] = {**updated, 'subscriptionPage': True}
    for name in ('fullchain.pem', 'privkey.pem'):
        snapshot(plan, directory / 'certs' / name)
    if component == 'subscription-page' and not shared:
        parent_path = root / 'registry/panel.json'
        parent = runtime.load(parent_path) if parent_path.exists() else None
        if parent and parent.get('subscriptionMigration') and pages.identity(parent['subscriptionMigration']) == page_id:
            changed_parent = copy.deepcopy(parent)
            changed_parent['subscriptionMigration']['domain'] = hostname
            changed_parent['subscriptionUrls'] = [replace_host(url, old, hostname) for url in parent.get('subscriptionUrls', [])]
            plan['records'][str(parent_path)] = changed_parent
            snapshot(plan, parent_path)
            if changed_parent['subscriptionUrls'] != parent.get('subscriptionUrls', []):
                parent_item = {**parent, 'service': parent['mainService']}
                linked = add_unit(plan, parent_item, parent)
                configure_environment(plan, linked, [n for n in parent['applications'] if n != 'remnawave-subscription-page'],
                                      {'SUB_PUBLIC_DOMAIN': changed_parent['subscriptionUrls'][0].split('://', 1)[1]})
    # Local pages using the panel's public URL follow the changed panel address.
    if component == 'panel':
        for page, related in pages.records(root).items():
            if related.get('companion'):
                continue
            current = pages.inspect(related)
            endpoint = runtime.environment(current or {}).get('REMNAWAVE_PANEL_URL', '')
            if urlsplit(endpoint).hostname != old:
                continue
            linked = add_unit(plan, related, {**related, 'component': 'subscription-page', 'mainService': related['service'], 'applications': [related['service']]})
            configure_environment(plan, linked, [related['service']], {'REMNAWAVE_PANEL_URL': replace_host(endpoint, old, hostname)})
            page_record = root / 'registry/subscription-pages' / (page + '.json')
            if page_record.exists():
                snapshot(plan, page_record)
                plan['records'][str(page_record)] = runtime.load(page_record)
    for unit in plan['units']:
        # Validate candidates in their original project context before any change.
        candidate = backup / ('candidate-' + str(plan['units'].index(unit)) + '.json')
        runtime.write(candidate, unit['after'])
        command(candidate_base(unit['item'], candidate), '--profile', '*', 'config', '--quiet')
    runtime.write(backup / 'plan.json', plan)
    return backup / 'plan.json'


def restore_processes(plan, original=False):
    for unit in plan['units']:
        item = unit['item'] if original else unit.get('committedItem', unit['item'])
        services = [name for name in unit['services'] if not (original and unit.get('addedProxy') and name == 'node-nginx')]
        for running in (False, True):
            names = [name for name in services if unit['running'].get(name, False) is running]
            if names:
                command(compose_base(item), 'up', '--force-recreate', '--no-deps', '--no-build', '--pull', 'never',
                        *(['-d'] if running else ['--no-start']), *names)
        for name in services:
            if unit['running'].get(name):
                pages.ready({**item, 'service': name})


def rollback(path):
    plan = runtime.load(path)
    if plan['phase'] in ('complete', 'rolled-back', 'prepared'):
        return
    for unit in plan['units']:
        if unit.get('addedProxy'):
            candidate = Path(plan['backup']) / ('candidate-' + str(plan['units'].index(unit)) + '.json')
            command(candidate_base(unit['item'], candidate), 'rm', '--stop', '--force', 'node-nginx')
        folder = Path(unit.get('commitBackup', ''))
        if (folder / 'compose-files.before.json').is_file():
            runtime.restore_compose(folder)
    for name, value in plan['files'].items():
        target = safe_file(name, optional=True)
        if value['before'] is None:
            target.unlink(missing_ok=True)
        else:
            runtime.write(target, base64.b64decode(value['before']).decode(), value['mode'])
    restore_processes(plan, original=True)
    plan['phase'] = 'rolled-back'
    runtime.write(path, plan)


def stop_proxy(path):
    plan = runtime.load(path)
    plan['phase'] = 'applying'
    runtime.write(path, plan)
    unit = plan['units'][0]
    if unit['running'].get(plan['proxy']) and not unit.get('addedProxy'):
        command(compose_base(unit['item']), 'stop', plan['proxy'])


def apply(path, certificate=None, key=None):
    plan = runtime.load(path)
    if plan['phase'] not in ('prepared', 'applying'):
        raise ManagementError('Операция уже завершена')
    for name, value in plan['files'].items():
        target = safe_file(name, optional=True)
        current = base64.b64encode(target.read_bytes()).decode() if target.exists() else None
        if current != value['before']:
            raise ManagementError('Настройки изменились после подготовки. Повторите смену домена')
    plan['phase'] = 'applying'
    runtime.write(path, plan)
    try:
        if plan['method'] != 'auto':
            try:
                tls.copy_pair(plan['certificateDomain'], certificate, key, plan['directory'], plan['certificateSubscriptions'])
            except ValueError as error:
                raise ManagementError(str(error)) from error
            for state in [plan['tlsState'], *plan['records'].values()]:
                state['tls'] = {'method': plan['method'], 'certificate': str(Path(certificate).absolute()), 'key': str(Path(key).absolute())}
        for name, value in plan['files'].items():
            if 'after' in value:
                runtime.write(name, value['after'], value['mode'])
        for index, unit in enumerate(plan['units']):
            if unit['after'] != unit['before']:
                folder = Path(plan['backup']) / ('compose-' + str(index))
                folder.mkdir(mode=0o700)
                runtime.write(folder / 'state.before.json', unit['state'])
                runtime.write(folder / 'state.json', unit['state'])
                runtime.write(folder / 'candidate.json', unit['after'])
                unit['commitBackup'] = str(folder)
                runtime.write(path, plan)
                runtime.commit_compose(folder / 'state.json', folder / 'candidate.json', folder, '', '', preserve_release=True)
                unit['committedItem'] = {**unit['item'], 'composeFiles': runtime.load(folder / 'state.json')['composeFiles']}
                for record in plan['records'].values():
                    if record.get('directory') == unit['item']['directory'] and record.get('project') == unit['item']['project']:
                        record['composeFiles'] = unit['committedItem']['composeFiles']
                    migrated = record.get('subscriptionMigration')
                    if migrated and migrated.get('directory') == unit['item']['directory'] and migrated.get('project') == unit['item']['project']:
                        migrated['composeFiles'] = unit['committedItem']['composeFiles']
                runtime.write(path, plan)
        unit = plan['units'][0]
        base = compose_base(unit.get('committedItem', unit['item']))
        if plan['proxy'] == 'caddy':
            command(base, 'run', '--rm', '--no-deps', '--entrypoint', 'caddy', 'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile')
        else:
            command(base, 'run', '--rm', '--no-deps', '--entrypoint', 'nginx', 'node-nginx', '-t')
        restore_processes(plan)
        for name, state in plan['records'].items():
            runtime.write(name, state)
        for unit in plan['units']:
            runtime.write_layout({**unit['state'], 'composeFiles': unit.get('committedItem', unit['item'])['composeFiles']}, unit['after'])
        plan['phase'] = 'applied'
        runtime.write(path, plan)
    except BaseException:
        rollback(path)
        raise


def description(root, component, page_id=None):
    record, state, item = deployment(root, component, page_id)
    return {'component': component, 'directory': item['directory'], 'composeFiles': item['composeFiles'],
            'domain': item.get('domain') if component == 'subscription-page' else state.get('panelDomain' if component == 'panel' else 'nodeDomain', ''),
            'tlsMethod': state.get('tls', {}).get('method', 'auto'), 'filesMap': str(Path(item['directory']) / 'FILES.txt')}


def verify_https(plan):
    unit = plan['units'][0]
    if plan['proxy'] != 'caddy' or not unit['running'].get('caddy'):
        return
    panel = plan['component'] == 'panel'
    url = 'https://' + plan['domain'] + ('/api/auth/status' if panel else '/')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            with opener.open(url, timeout=5) as response:
                if not unit['running'].get(unit['item']['service']):
                    return
                if panel:
                    body = json.loads(response.read(1024 * 1024 + 1))
                    if not isinstance(body, dict) or not isinstance(body.get('response'), dict) or not isinstance(body['response'].get('isLoginAllowed'), bool):
                        raise ValueError('Новый адрес не вернул ответ панели')
                return
        except urllib.error.HTTPError as error:
            # The normal bare subscription-page URL has no user's UUID.
            if (not panel and error.code == 404) or not unit['running'].get(unit['item']['service']):
                return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(2)
    raise ManagementError('HTTPS нового домена не подтверждён; прежние настройки восстановлены')


def complete(path):
    plan = runtime.load(path)
    if plan['phase'] != 'applied':
        raise ManagementError('Домен ещё не применён')
    try:
        verify_https(plan)
        plan['phase'] = 'complete'
        runtime.write(path, plan)
    except BaseException:
        rollback(path)
        raise


def dispatch(args):
    if args.operation == 'apply':
        apply(args.plan, args.certificate, args.key)
    elif args.operation == 'rollback':
        rollback(args.plan)
    elif args.operation == 'complete':
        complete(args.plan)
    elif args.operation == 'stop-proxy':
        stop_proxy(args.plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'apply', 'complete', 'rollback', 'stop-proxy', 'info'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--component', choices=['panel', 'node', 'subscription-page'])
    for name in ('page-id', 'domain', 'plan', 'certificate', 'key'):
        parser.add_argument('--' + name)
    args = parser.parse_args()
    if args.operation == 'prepare':
        print(prepare(args.root, args.component, args.domain, args.page_id))
    elif args.operation in ('apply', 'rollback', 'complete', 'stop-proxy'):
        import fcntl
        plan = safe_file(args.plan)
        descriptor = os.open(plan.with_suffix('.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            dispatch(args)
    else:
        print(json.dumps(description(args.root, args.component, args.page_id), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda *_: sys.exit(1))
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(str(error) if isinstance(error, (runtime.ConfigurationError, ManagementError)) else 'Смена адреса не завершена; проверьте приватный журнал и резервную копию')
