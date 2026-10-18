#!/usr/bin/env python3
"""Validated filesystem and Compose operations for the Remnacust installer."""
import argparse
import base64
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import threading
import uuid
from urllib.parse import urlsplit


class ConfigurationError(ValueError):
    """A diagnostic written by the installer without rejected secret values."""


def fail(message):
    raise ConfigurationError(message)


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write(path, value, mode=0o600):
    target = Path(path)
    if target.is_symlink():
        fail('Не записываем файл через символическую ссылку: ' + str(target))
    target.parent.mkdir(parents=True, exist_ok=True)
    data = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2) + '\n'
    fd, name = tempfile.mkstemp(prefix='.remnacust-', dir=target.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, target)
        if os.name != 'nt':
            directory_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def domain(value):
    if len(value) > 253 or not re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', value):
        fail('Укажите домен без протокола, порта и пути')
    return value.lower()


def subscription_urls(value, hostname):
    if not value:
        return ['https://' + domain(hostname) + '/api/sub']
    if len(value) > 2050:
        fail('Адреса сайта подписки слишком длинные')
    entries = value.split(',')
    if not 1 <= len(entries) <= 2:
        fail('Укажите один или два адреса сайта подписки через запятую')
    result = []
    for entry in entries:
        entry = entry.strip()
        if entry.lower().startswith('https://'):
            entry = entry[8:]
        if len(entry) > 1024:
            fail('Адрес сайта подписки слишком длинный')
        match = re.fullmatch(r'([^/]+)((?:/[A-Za-z0-9._~-]+)*)/?', entry)
        if not match or any(segment in {'.', '..'} for segment in match[2].split('/')):
            fail('Адрес подписки: домен или HTTPS-адрес с путём, без порта, параметров и токена пользователя')
        url = 'https://' + domain(match[1]) + match[2]
        if url in result:
            fail('Адреса сайта подписки должны различаться')
        result.append(url)
    return result


def subscription_domains(value, hostname):
    if not value:
        fail('Укажите один или два домена сайта подписки')
    urls = subscription_urls(value, hostname)
    hosts = [url[8:] for url in urls]
    if any('/' in host or host == domain(hostname) for host in hosts):
        fail('Сайту подписки нужен отдельный домен без пути; домен панели использовать нельзя')
    return hosts


def subscription_env(token):
    if not re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', token):
        fail('Не получен API-токен сайта подписки')
    return ('APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://remnawave:3000\n'
            'REMNAWAVE_API_TOKEN=' + token + '\nINTERNAL_JWT_SECRET=' + secrets.token_hex(32) +
            '\nTRUST_PROXY=1\nMARZBAN_LEGACY_LINK_ENABLED=false\n')


def port(value):
    if not re.fullmatch(r'[0-9]{1,5}', str(value)) or not 1 <= int(value) <= 65535:
        fail('Порт должен быть от 1 до 65535')
    return int(value)


def project_name(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', value):
        fail('Некорректное имя проекта Compose')
    return value


def environment(container):
    result = {}
    for value in container.get('Config', {}).get('Env') or []:
        if '=' in value:
            key, content = value.split('=', 1)
            result[key] = content
    return result


def database_network(container, peers, override=''):
    """Select the network on which the live database hostname belongs."""
    mode = container.get('HostConfig', {}).get('NetworkMode')
    if mode == 'host':
        if override and override != 'host':
            fail('Указанная сеть БД не совпадает с host-сетью панели')
        return 'host'
    networks = container.get('NetworkSettings', {}).get('Networks') or {}
    if not networks:
        fail('У контейнера панели нет сети Docker для доступа к базе')
    if override and override not in networks:
        fail('Указанная сеть БД не подключена к контейнеру панели')
    if len(networks) == 1:
        return next(iter(networks))

    try:
        hostname = urlsplit(environment(container)['DATABASE_URL']).hostname
    except (KeyError, ValueError):
        hostname = None
    if not hostname:
        fail('Не удалось определить адрес базы из DATABASE_URL')
    hostname = hostname.lower()
    matches = {}
    for peer in peers:
        if peer.get('Id') == container.get('Id') or peer.get('State', {}).get('Running') is not True:
            continue
        identity = peer.get('Id') or peer.get('Name')
        for name, endpoint in (peer.get('NetworkSettings', {}).get('Networks') or {}).items():
            if name not in networks:
                continue
            aliases = {alias.lower() for alias in (endpoint.get('Aliases') or []) if isinstance(alias, str)}
            aliases.add(str(peer.get('Name') or '').lstrip('/').lower())
            addresses = {str(endpoint.get(key) or '').lower() for key in ('IPAddress', 'GlobalIPv6Address')}
            if hostname in aliases or hostname in addresses:
                matches.setdefault(name, set()).add(identity)
    targets = set().union(*matches.values()) if matches else set()
    if len(targets) > 1:
        fail('Адрес базы совпадает с несколькими контейнерами Docker; проверьте DATABASE_URL и сети')
    if override:
        if targets and override not in matches:
            fail('Указанная сеть БД не ведёт к контейнеру из DATABASE_URL')
        return override
    if not targets:
        fail('Не удалось определить сеть БД среди сетей панели. Для внешней БД задайте REMNACUST_DATABASE_NETWORK')
    if mode in matches:
        return mode
    return sorted(matches)[0]


def compose_environment(value):
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    if isinstance(value, list):
        result = {}
        for entry in value:
            if not isinstance(entry, str):
                fail('В списке Compose environment должны быть строки KEY=VALUE или KEY')
            key, separator, content = entry.partition('=')
            if not key:
                fail('В Compose environment найдено пустое имя переменной')
            result[key] = content if separator else None
        return result
    fail('Compose environment должен быть объектом или списком переменных')


def inspect_one(path):
    value = load(path)
    if not isinstance(value, list) or len(value) != 1:
        fail('Неоднозначный контейнер приложения')
    return value[0]


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def backup_hashes(directory):
    root = Path(directory)
    files = sorted(p for p in root.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
    if any(p.is_symlink() or not re.fullmatch(r'[A-Za-z0-9_.-]+', p.name) for p in files):
        fail('Некорректный файл резервной копии')
    write(root/'SHA256SUMS', ''.join(file_sha256(p)+'  '+p.name+'\n' for p in files))


def verify_backup(directory, component='panel'):
    root = Path(directory)
    names = set()
    for row in (root/'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', row)
        if not match or match[2] in names:
            fail('Некорректный список контрольных сумм')
        path = root/match[2]
        if path.is_symlink() or not path.is_file() or file_sha256(path) != match[1]:
            fail('Контрольная сумма резервной копии не совпадает')
        names.add(match[2])
    required = {'container.before.json', 'state.before.json', 'env-files.json', 'compose.before.json'}
    if component == 'panel':
        required.add('database.dump')
    elif component != 'node':
        fail('Unknown backup component')
    if not required <= names:
        fail('Неполная резервная копия панели')
    state = load(root/'state.before.json')
    if component == 'node' and state.get('component') != 'node':
        fail('Not a node state backup')
    required.update('original-'+str(i) for i in range(len(state['composeFiles'])))
    required.update(load(root/'env-files.json').values())
    required.update(name for name in ['environment.before', 'fingerprints.json'] if (root/name).exists())
    if (root/'compose-files.before.json').exists():
        required.add('compose-files.before.json')
        manifest = load(root/'compose-files.before.json')
        required.update(item['backup'] for item in manifest['files'] if item['existed'])
        if manifest.get('nodeStateRollback'):
            required.add('node-state-rollback.json')
    if not required <= names:
        fail('Файл конфигурации не подтверждён контрольной суммой')


def compose_path(directory, value):
    path = Path(value)
    if not path.is_absolute():
        path = directory/path
    if path.is_symlink() or not path.resolve().is_relative_to(directory) or path.resolve() == directory:
        fail('Compose-файл должен быть обычным файлом внутри каталога установки')
    if path.exists() and not path.is_file():
        fail('Compose-файл не является обычным файлом')
    return path.resolve()



def neutral_compose_overrides(deployment, active):
    """Recognize empty layers left after consolidation; never ignore real overrides."""
    result = []
    for name in ['compose.override.yaml', 'compose.override.yml', 'docker-compose.override.yaml', 'docker-compose.override.yml']:
        path = deployment / name
        if not path.exists() and not path.is_symlink():
            continue
        path = compose_path(deployment, path)
        if path in active:
            continue
        try:
            neutral = path.stat().st_size <= 8 * 1024 * 1024 and load(path) == {'services': {}}
        except (OSError, ValueError):
            neutral = False
        if not neutral:
            fail('Неактивный Compose override необходимо включить в конфигурацию перед операцией')
        result.append(path)
    return result


def restore_compose(directory):
    backup = Path(directory)
    manifest = backup/'compose-files.before.json'
    if not manifest.exists():
        return  # Backups made before in-place Compose updates have the old restore path.
    if manifest.is_symlink():
        fail('Некорректный манифест Compose-копии')
    record = load(manifest)
    deployment = Path(load(backup/'state.before.json')['directory']).resolve()
    if record['directory'] != str(deployment) or not 1 <= len(record['files']) <= 33:
        fail('Некорректный каталог Compose-копии')
    files = []
    for item in record['files']:
        target = compose_path(deployment, item['path'])
        content = None
        if item['existed']:
            if not re.fullmatch(r'compose-original-[0-9]+', item['backup']):
                fail('Некорректное имя Compose-копии')
            original = backup/item['backup']
            if original.is_symlink() or not original.is_file() or file_sha256(original) != item['sha256']:
                fail('Контрольная сумма Compose-копии не совпадает')
            content = original.read_bytes().decode('utf-8')
        files.append((target, content, item['mode']))
    if len({path for path, _, _ in files}) != len(files):
        fail('Дублированный Compose-файл в копии')
    persistent = None
    if record.get('nodeStateRollback'):
        checkpoint = backup / 'node-state-rollback.json'
        if checkpoint.is_symlink() or not checkpoint.is_file() or file_sha256(checkpoint) != record['nodeStateRollback']:
            fail('Persistent node state rollback configuration failed its checksum')
        persistent = load(checkpoint)
        if persistent['directory'] != str(deployment):
            fail('Persistent node state belongs to another deployment')
        primary = compose_path(deployment, persistent['primary'])
        if primary not in {path for path, _, _ in files}:
            fail('Persistent node state rollback has an unknown Compose path')
        for item in persistent['copies']:
            target = Path(item['target'])
            if target.is_symlink() or target.parent.parent.resolve() != deployment or not re.fullmatch(r'\.remnacust-node-state-[a-f0-9]{32}', target.parent.name) or target.name != NODE_STATE_DIRECTORIES.get(item['source']) or not target.is_dir():
                fail('Persistent node state rollback mount is unavailable')
    for target, content, mode in files:
        if content is None:
            target.unlink(missing_ok=True)
        else:
            if not target.exists() or file_sha256(target) != hashlib.sha256(content.encode('utf-8')).hexdigest():
                write(target, content, mode=mode & 0o777)
    if persistent:
        # Recreate the previous IMAGE, using the newest persistent state. Copying
        # an old quota journal back would reissue credit consumed after startup.
        write(primary, persistent['config'])
        for path in persistent['composeFiles']:
            layer = compose_path(deployment, path)
            if layer != primary:
                write(layer, {'services': {}})


def plan_panel_data_restore(config, state, archived, container, image, resolved=None, active=None, environment_config=None):
    """Restore database identity without rolling deployment wiring backwards."""
    if state.get('component') != 'panel' or archived.get('component') != 'panel':
        fail('Восстановление данных требует установку и копию панели')
    if not isinstance(image, str) or not image or len(image) > 512 or re.search(r'\s|\x00|\$', image):
        fail('Не определён неизменяемый установленный образ панели')
    version = state.get('version')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', version):
        fail('Не определена версия установленной панели')
    archived_version = archived.get('version')
    if archived_version is not None:
        if not isinstance(archived_version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', archived_version):
            fail('Некорректная версия панели в копии')
        parts = lambda value: tuple((list(map(int, value.split('.'))) + [0] * 4)[:4])
        if parts(archived_version) > parts(version):
            fail('Сначала обновите панель до версии резервной копии; понижение схемы не поддерживается')
    applications = state.get('applications')
    old_applications = archived.get('applications')
    running = archived.get('runningApplications', old_applications)
    if (not isinstance(applications, list) or not applications or len(applications) > 1000 or
            any(not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) for name in applications) or
            len(set(applications)) != len(applications) or not isinstance(old_applications, list) or
            any(not isinstance(name, str) for name in old_applications) or
            not isinstance(running, list) or any(not isinstance(name, str) for name in running) or len(set(running)) != len(running) or
            any(name not in old_applications for name in running)):
        fail('Некорректный список процессов панели в установке или копии')
    main, old_main = state.get('mainService'), archived.get('mainService')
    services = config.get('services', {})
    if main not in applications or main not in services or old_main not in old_applications:
        fail('Основная служба панели отсутствует в установке или копии')
    mapped = [main if name == old_main else name for name in running]
    if len(set(mapped)) != len(mapped) or any(name not in applications for name in mapped):
        fail('Работающие службы из копии не сопоставлены текущей установке')
    secret = environment(container).get('APP_SECRET', '')
    if not 32 <= len(secret) <= 4096 or any(ch in secret for ch in ['\r', '\n', '\x00']):
        fail('В копии отсутствует корректный исходный APP_SECRET')
    deployment = Path(state['directory']).resolve()
    files = [compose_path(deployment, value) for value in state['composeFiles']]
    if not 1 <= len(files) <= 32 or len(set(files)) != len(files):
        fail('Нужен определённый набор Compose-файлов панели')
    primary = panel_compose_primary(deployment, files, state.get('composeEntryPoint'))
    paths = list(dict.fromkeys([*files, primary]))
    paths.extend(neutral_compose_overrides(deployment, files))
    originals = []
    for path in paths:
        if path.exists() and not path.is_file():
            fail('Некорректный Compose-файл панели')
        originals.append({'path': str(path), 'sha256': file_sha256(path) if path.exists() else None})
    inputs = [deployment / '.env']
    for service in (environment_config or config).get('services', {}).values():
        for value in service.get('env_file', []):
            value = value.get('path') if isinstance(value, dict) else value
            if not isinstance(value, str):
                fail('Некорректный env_file в конфигурации панели')
            path = Path(value)
            inputs.append(path if path.is_absolute() else deployment / path)
    fingerprints = []
    for path in dict.fromkeys(inputs):
        if path.exists() and not path.is_file():
            fail('Некорректный файл окружения панели')
        fingerprints.append({'path': str(path), 'sha256': file_sha256(path) if path.exists() else None})
    desired = copy.deepcopy(config)
    if config.get('name', state['project']) != state['project']:
        fail('Compose-конфигурация принадлежит другому проекту')
    subscription_services = []
    for name in applications:
        service = desired['services'].get(name)
        if not isinstance(service, dict):
            fail('В текущем Compose отсутствует процесс панели')
        effective = (resolved or config).get('services', {}).get(name)
        if not isinstance(effective, dict):
            fail('Не определена действующая конфигурация процесса панели')
        labels = effective.get('labels') or {}
        if isinstance(labels, list):
            labels = dict(value.split('=', 1) for value in labels if '=' in value)
        if labels.get('io.remnacust.service-role') == 'subscription-page':
            if name == main:
                fail('Основная служба панели не может быть сайтом подписки')
            subscription_services.append(name)
            continue
        repository = (effective.get('image') or '').split('@', 1)[0].rsplit('/', 1)[-1].split(':', 1)[0]
        if repository in {'postgres', 'postgresql', 'redis', 'valkey', 'nginx', 'caddy', 'traefik'}:
            fail('Процесс панели ошибочно указывает на инфраструктурную службу')
        service['image'] = image
        service.pop('build', None)
        # This config intentionally retains original interpolation and env_file
        # references. Only the newly inserted literal needs Compose escaping.
        service['environment'] = {**compose_environment(service.get('environment')), 'APP_SECRET': secret.replace('$', '$$')}
    effective_services = (resolved or config)['services']
    main_env = compose_environment(effective_services[main].get('environment'))
    live_url = environment(active).get('DATABASE_URL') if active is not None else main_env.get('DATABASE_URL')
    for name, service in effective_services.items():
        if name in applications:
            continue
        env = compose_environment(service.get('environment'))
        labels = service.get('labels') or {}
        if isinstance(labels, list):
            labels = dict(value.split('=', 1) for value in labels if '=' in value)
        url = env.get('DATABASE_URL')
        writer = (env.get('INSTANCE_TYPE') in {'api', 'processor', 'scheduler'} or
                  (bool(effective_services[main].get('image')) and service.get('image') == effective_services[main]['image']) or
                  (isinstance(url, str) and url.replace('$$', '$') == live_url))
        if writer or labels.get('io.remnacust.service-role') == 'subscription-page':
            fail('Найдена незарегистрированная служба панели: ' + name + '; обновите список приложений перед восстановлением')
    database = None
    if active is not None:
        live = environment(active)
        url = live.get('DATABASE_URL', '')
        if not url or any(ch in url for ch in ['\r', '\n', '\x00']):
            fail('Не определено действующее подключение к БД панели')
        effective_env = compose_environment((resolved or config)['services'][main].get('environment'))
        declared = effective_env.get('DATABASE_URL')
        if declared is not None and declared.replace('$$', '$') != url:
            fail('Подключение к БД в Compose отличается от установленного контейнера; примените настройки перед восстановлением')
        database = {'DATABASE_URL': url, 'APP_SECRET': secret}
    result = copy.deepcopy(state)
    result.update(image=image, runningApplications=mapped, composeFiles=[str(primary)], composeEntryPoint=str(primary))
    if subscription_services:
        token_uuid = archived.get('subscriptionTokenUuid') if archived.get('subscriptionPage') else state.get('subscriptionTokenUuid')
        if not state.get('subscriptionPage') or not isinstance(token_uuid, str) or not re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', token_uuid):
            fail('Для сайта подписки необходима зарегистрированная служебная учётная запись')
        result['subscriptionTokenUuid'] = token_uuid
    return {'version': 1, 'directory': str(deployment), 'primary': str(primary),
            'originals': originals, 'inputs': fingerprints, 'config': desired, 'state': result, 'database': database, 'subscriptionServices': subscription_services}


def panel_compose_primary(deployment, paths, entry):
    if entry:
        return compose_path(deployment, entry)
    if re.fullmatch(r'compose\.remnacust-[0-9]{8}T[0-9]{6}Z-[0-9]+\.json', paths[0].name):
        candidates = [deployment / name for name in ['compose.json', 'compose.yaml', 'compose.yml', 'docker-compose.yml', 'docker-compose.yaml'] if (deployment / name).exists()]
        if len(candidates) > 1:
            fail('Несколько основных Compose-файлов: выберите нужный через --compose-file')
        return compose_path(deployment, candidates[0] if candidates else deployment / 'compose.json')
    return paths[0]


def validate_panel_data_restore(plan):
    if plan.get('version') != 1 or plan.get('state', {}).get('component') != 'panel':
        fail('Некорректный план восстановления панели')
    deployment = Path(plan['directory']).resolve()
    if (Path(plan['state']['directory']).resolve() != deployment or
            plan.get('config', {}).get('name', plan['state']['project']) != plan['state']['project']):
        fail('План восстановления относится к другой установке')
    for item in [*plan['originals'], *plan.get('inputs', [])]:
        path = Path(item['path'])
        current = file_sha256(path) if path.is_file() else None
        if current != item['sha256']:
            fail('Compose или окружение изменены после подготовки восстановления; повторите операцию')


def commit_panel_data_restore(plan, state_path):
    validate_panel_data_restore(plan)
    deployment = Path(plan['directory']).resolve()
    primary = compose_path(deployment, plan['primary'])
    paths = []
    for item in plan['originals']:
        path = compose_path(deployment, item['path'])
        paths.append(path)
    if primary not in paths or len(set(paths)) != len(paths):
        fail('Некорректный набор Compose-файлов в плане восстановления')
    write(primary, plan['config'])
    for path in paths:
        if path != primary:
            write(path, {'services': {}})
    write(state_path, plan['state'])



def restore_panel_subscription_token(plan, token):
    """Replace only the managed page credential after restoring signing identity."""
    if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', token) or len(token) > 16384:
        fail('Некорректный служебный токен сайта подписки')
    deployment = Path(plan['directory']).resolve()
    primary = compose_path(deployment, plan['primary'])
    config = load(primary)
    if config != plan['config']:
        fail('Compose изменён во время восстановления; служебный токен не записан')
    services = plan.get('subscriptionServices', [])
    if not services or any(name not in plan['state']['applications'] for name in services):
        fail('Не определена управляемая служба сайта подписки')
    for name in services:
        service = config['services'][name]
        service['environment'] = {**compose_environment(service.get('environment')), 'REMNAWAVE_API_TOKEN': token}
    write(primary, config)


def preserve_node_state_rollback(plan_path, directory):
    backup = Path(directory)
    verify_backup(backup, component='node')
    plan = load(plan_path)
    if not plan['copies']:
        return
    before = load(backup / 'state.before.json')
    deployment = Path(before['directory']).resolve()
    if before['component'] != 'node' or plan['directory'] != str(deployment):
        fail('Persistent rollback plan belongs to another component')
    manifest = load(backup / 'compose-files.before.json')
    if manifest['directory'] != str(deployment):
        fail('Persistent rollback plan belongs to another deployment')
    primary = compose_path(deployment, manifest['files'][0]['path'])
    config = load(backup / 'compose.before.json')
    service = config['services'][before['mainService']]
    for item in plan['copies']:
        target = Path(item['target'])
        if target.is_symlink() or target.parent.parent.resolve() != deployment or not re.fullmatch(r'\.remnacust-node-state-[a-f0-9]{32}', target.parent.name) or target.name != NODE_STATE_DIRECTORIES.get(item['source']) or not target.is_dir():
            fail('Persistent rollback state is not a completed owned snapshot')
        service.setdefault('volumes', []).append({'type': 'bind', 'source': str(target), 'target': item['source']})
    checkpoint = backup / 'node-state-rollback.json'
    write(checkpoint, {'directory': str(deployment), 'primary': str(primary), 'composeFiles': before['composeFiles'], 'copies': plan['copies'], 'config': config})
    manifest['nodeStateRollback'] = file_sha256(checkpoint)
    write(backup / 'compose-files.before.json', manifest)
    before.update(composeFiles=[str(primary)], composeEntryPoint=str(primary))
    write(backup / 'state.before.json', before)
    backup_hashes(backup)


def commit_compose(state_path, candidate_path, directory, version, release):
    backup = Path(directory)
    before = load(backup/'state.before.json')
    deployment = Path(before['directory']).resolve()
    if not deployment.is_dir() or deployment == Path(deployment.anchor):
        fail('Некорректный каталог установки')
    active = before['composeFiles']
    if not 1 <= len(active) <= 32:
        fail('Нужен определённый набор Compose-файлов')
    paths = [compose_path(deployment, value) for value in active]
    if len(set(paths)) != len(paths) or not all(path.is_file() for path in paths):
        fail('Compose-файлы отсутствуют или дублируются')
    primary = before.get('composeEntryPoint')
    if primary:
        primary = compose_path(deployment, primary)
    elif re.fullmatch(r'compose\.remnacust-[0-9]{8}T[0-9]{6}Z-[0-9]+\.json', paths[0].name):
        # Recover the original entry point used by earlier installers, instead
        # of perpetuating their timestamped shadow configuration.
        originals = [deployment/name for name in ['compose.json', 'compose.yaml', 'compose.yml', 'docker-compose.yml', 'docker-compose.yaml'] if (deployment/name).exists()]
        if len(originals) > 1:
            fail('Несколько основных Compose-файлов: выберите нужный через --compose-file')
        primary = compose_path(deployment, originals[0] if originals else deployment/'compose.json')
    else:
        primary = paths[0]
    paths.extend(neutral_compose_overrides(deployment, paths))
    config = load(candidate_path)
    state = load(state_path)
    if config.get('name', before['project']) != before['project'] or state['directory'] != before['directory'] or state['project'] != before['project']:
        fail('Compose-конфигурация принадлежит другому проекту')
    if not all(name in config.get('services', {}) for name in state['applications']):
        fail('В новой Compose-конфигурации отсутствует приложение')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', version) or not re.fullmatch(r'v[0-9]+(?:\.[0-9]+){1,3}', release):
        fail('Некорректная версия Compose-конфигурации')
    targets = list(dict.fromkeys([primary, *paths]))
    manifest = backup/'compose-files.before.json'
    if manifest.exists():
        fail('План Compose уже существует; используйте новую резервную копию')
    records = []
    for index, path in enumerate(targets):
        if path.exists() and path.stat().st_size > 8*1024*1024:
            fail('Compose-файл слишком большой')
        item = {'path': str(path), 'existed': path.exists(), 'backup': 'compose-original-'+str(index), 'mode': 0o600}
        if path.exists():
            item.update(mode=path.stat().st_mode & 0o777, sha256=file_sha256(path))
            write(backup/item['backup'], path.read_bytes().decode('utf-8'))
        records.append(item)
    write(manifest, {'directory': str(deployment), 'files': records})
    backup_hashes(backup)
    original_state = Path(state_path).read_text(encoding='utf-8')
    config['x-remnacust-release'] = {'installer': release, 'component': before['component'], 'version': version}
    try:
        write(primary, config)
        # Effective settings from every active layer are now in the primary
        # file. Empty overlays prevent old image pins from overriding it.
        for path in paths:
            if path != primary:
                write(path, {'services': {}})
        state.update(composeFiles=[str(primary)], composeEntryPoint=str(primary))
        write(state_path, state)
    except Exception:
        restore_compose(backup)
        write(state_path, original_state)
        raise
    print('Основной Compose обновлён: ' + str(primary))


def discover(container, component, directory=None, compose_file=None):
    labels = container.get('Config', {}).get('Labels') or {}
    project = labels.get('com.docker.compose.project')
    service = labels.get('com.docker.compose.service')
    if not project or not service:
        fail('Контейнер не управляется Compose; сначала подготовьте Compose-конфигурацию')
    project_name(project)
    working = Path(directory or labels.get('com.docker.compose.project.working_dir') or '').resolve()
    if not working.is_dir() or working == Path('/'):
        fail('Не найден рабочий каталог Compose; используйте --directory')
    files = [compose_file] if compose_file else (labels.get('com.docker.compose.project.config_files') or '').split(',')
    files = [str((working / p).resolve()) for p in files if p]
    if not files or any(not Path(p).is_file() for p in files):
        fail('Не найдены исходные файлы Compose; используйте --compose-file')
    env = environment(container)
    if component == 'panel':
        if not env.get('DATABASE_URL') or not env.get('APP_SECRET'):
            fail('Нужны исходные DATABASE_URL и APP_SECRET; существующие секреты не заменяются')
    elif not env.get('SECRET_KEY'):
        fail('У существующей ноды нет SECRET_KEY')
    state = {'schema': 1, 'component': component, 'directory': str(working), 'project': project,
            'composeFiles': files, 'mainService': service, 'container': container['Id'],
            'applications': [service], 'extraServices': []}
    if component == 'node':
        state['apiPort'] = port(env.get('NODE_PORT', '2222'))
    return state


def transform(config, container, component, image, containers=(), subscription_image=''):
    result = copy.deepcopy(config)
    labels = container.get('Config', {}).get('Labels') or {}
    main = labels.get('com.docker.compose.service')
    services = result.get('services') or {}
    if main not in services:
        fail('Основная служба отсутствует в Compose')
    original_image = services[main].get('image')
    applications = []
    roles = {(c.get('Config', {}).get('Labels') or {}).get('com.docker.compose.service'): environment(c).get('INSTANCE_TYPE') for c in containers}
    for name, service in services.items():
        if (component == 'panel' and subscription_image and
                (service.get('labels') or {}).get('io.remnacust.service-role') == 'subscription-page'):
            service['image'] = subscription_image
            service.pop('build', None)
            applications.append(name)
            continue
        repository = (service.get('image') or '').split('@', 1)[0].rsplit('/', 1)[-1].split(':', 1)[0]
        if repository in {'caddy', 'nginx', 'nginx-proxy', 'nginx-proxy-manager', 'traefik', 'postgres', 'postgresql', 'valkey', 'redis'}:
            if name == main:
                fail('Основной контейнер является прокси или БД, а не приложением')
            continue
        env = compose_environment(service.get('environment'))
        role = roles.get(name) or env.get('INSTANCE_TYPE')
        worker = component == 'panel' and (role in {'api', 'processor', 'scheduler'} or name in {'remnawave-processor', 'remnawave-scheduler'})
        same_image = bool(original_image) and service.get('image') == original_image
        if name == main or worker or same_image:
            applications.append(name)
            service['image'] = image
            service.pop('build', None)
            if component == 'node' and name == main:
                current = environment(container)
                protected = {key: current[key] for key in ['SECRET_KEY'] if key in current}
                protected['NODE_PORT'] = str(port(current.get('NODE_PORT', '2222')))
                if isinstance(service.get('environment'), list):
                    service['environment'] = [entry.partition('=')[0] + '=' + protected[entry.partition('=')[0]]
                        if entry.partition('=')[0] in protected else entry for entry in service['environment']]
                    service['environment'].extend(key + '=' + value for key, value in protected.items() if key not in env)
                elif protected:
                    service['environment'] = {**env, **protected}
    return result, applications


def panel_env(template, hostname, host_port, subscriptions=''):
    hostname = domain(hostname)
    password = secrets.token_hex(32)
    values = {'APP_SECRET': secrets.token_hex(32), 'POSTGRES_PASSWORD': password,
              'POSTGRES_USER': 'postgres', 'POSTGRES_DB': 'postgres',
              'DATABASE_URL': f'postgresql://postgres:{password}@remnawave-db:5432/postgres',
              'FRONT_END_DOMAIN': 'https://' + hostname, 'PANEL_DOMAIN': hostname,
              'SUB_PUBLIC_DOMAIN': subscription_urls(subscriptions, hostname)[0][8:], 'HWID_ENABLED_DEFAULT': 'true',
              'METRICS_USER': 'admin', 'METRICS_PASS': secrets.token_hex(24),
              'WEBHOOK_SECRET_HEADER': secrets.token_hex(32)}
    text = template
    for key, value in values.items():
        pattern = r'^' + re.escape(key) + r'=.*$'
        if re.search(pattern, text, re.M):
            text = re.sub(pattern, lambda _: key + '=' + value, text, flags=re.M)
        else:
            text += '\n' + key + '=' + value + '\n'
    return text


def node_env(secret, number):
    number = port(number)
    if not secret or any(c in secret for c in "'\r\n\x00"):
        fail('Некорректный ключ ноды; вставьте SECRET_KEY из панели целиком')
    try:
        payload = json.loads(base64.b64decode(secret, validate=True))
        if any(not isinstance(payload.get(k), str) or not payload[k] for k in ['caCertPem', 'jwtPublicKey', 'nodeCertPem', 'nodeKeyPem']):
            raise ValueError()
    except (ValueError, TypeError):
        fail('SECRET_KEY должен содержать полный пакет сертификатов из панели')
    return f"NODE_PORT={number}\nSECRET_KEY='{secret}'\n"


def nginx_config(hostname):
    hostname = domain(hostname)
    return f'''server {{
    listen unix:/var/lib/remnacust/run/nginx.sock ssl proxy_protocol;
    server_name {hostname};
    ssl_certificate /var/lib/remnacust/tls/fullchain.pem;
    ssl_certificate_key /var/lib/remnacust/tls/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    http2 on;
    root /usr/share/nginx/html;
    location /xhttppath/ {{
        client_max_body_size 0;
        grpc_read_timeout 300s;
        grpc_send_timeout 300s;
        grpc_pass grpc://unix:/var/lib/remnacust/run/xhttp.sock;
    }}
    location / {{ try_files $uri $uri/ =404; }}
}}
'''


def fresh(component, directory, project, image, hostname='', number='3000', proxy='caddy', node_domain='', subscriptions='', subscription_image='', subscription_port='3010', panel_net_admin=False, node_net_admin=True):
    if panel_net_admin and component != 'panel':
        fail('Выбор NET_ADMIN панели доступен только для новой панели')
    directory = Path(directory).resolve()
    project_name(project)
    number = port(number)
    logging = {'driver': 'json-file', 'options': {'max-size': '30m', 'max-file': '5'}}
    common = {'restart': 'unless-stopped', 'logging': logging,
              'labels': {'io.remnacust.installer-managed': component},
              'ulimits': {'nofile': {'soft': 1048576, 'hard': 1048576}}}
    if component == 'panel':
        app = dict(common, image=image, env_file=[str(directory / '.env')],
                   ports=[f'127.0.0.1:{number}:3000'],
                   volumes=['valkey-socket:/var/run/valkey', 'backups:/opt/app/backups'],
                   depends_on={'remnawave-db': {'condition': 'service_healthy'}, 'remnawave-redis': {'condition': 'service_healthy'}},
                   healthcheck={'test': ['CMD-SHELL', 'curl -fsS http://localhost:3001/health'], 'interval': '10s', 'timeout': '5s', 'retries': 6, 'start_period': '30s'})
        if panel_net_admin:
            app['cap_add'] = ['NET_ADMIN']
        database = dict(common, image='postgres:18.4', env_file=[str(directory / '.env')],
                        shm_size='512mb', environment={'TZ': 'UTC'}, volumes=['database:/var/lib/postgresql'],
                        healthcheck={'test': ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}'], 'interval': '3s', 'timeout': '5s', 'retries': 20})
        redis = dict(common, image='valkey/valkey:9-alpine', volumes=['valkey-socket:/var/run/valkey'],
                     command=['valkey-server', '--save', '', '--appendonly', 'no', '--maxmemory-policy', 'noeviction', '--unixsocket', '/var/run/valkey/valkey.sock', '--unixsocketperm', '777', '--port', '0'],
                     healthcheck={'test': ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping'], 'interval': '3s', 'timeout': '5s', 'retries': 20})
        services = {'remnawave': app, 'remnawave-db': database, 'remnawave-redis': redis}
        if subscription_image:
            subscription_domains(subscriptions, hostname)
            subscription_port = port(subscription_port)
            if subscription_port == number or subscription_port in {80, 443}:
                fail('Порт сайта подписки должен отличаться от портов панели и HTTPS')
            services['remnawave-subscription-page'] = dict(common, image=subscription_image,
                labels={**common['labels'], 'io.remnacust.service-role': 'subscription-page'},
                env_file=[str(directory / 'subscription.env')], profiles=['subscription'],
                ports=[f'127.0.0.1:{subscription_port}:3010'],
                depends_on={'remnawave': {'condition': 'service_healthy'}},
                healthcheck={'test': ['CMD', 'node', '-e',
                    'fetch("http://127.0.0.1:3010/internal/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'],
                    'interval': '5s', 'timeout': '5s', 'retries': 12, 'start_period': '20s'})
        volumes = {name: {} for name in ['database', 'valkey-socket', 'backups']}
        if proxy == 'caddy':
            services['caddy'] = dict(common, image='caddy:2-alpine', ports=['80:80', '443:443', '443:443/udp'],
                                     volumes=[str(directory / 'Caddyfile') + ':/etc/caddy/Caddyfile:ro', 'caddy-data:/data', 'caddy-config:/config'])
            volumes.update({'caddy-data': {}, 'caddy-config': {}})
        result = {'name': project, 'services': services, 'volumes': volumes}
        extras = ['caddy'] if proxy == 'caddy' else []
        main = 'remnawave'
    else:
        main = 'remnanode'
        app = dict(common, image=image, network_mode='host', env_file=[str(directory / '.env')],
                   cap_add=['NET_ADMIN'] if node_net_admin else [], volumes=[str(directory / 'run') + ':/var/lib/remnacust/run', str(directory / 'logs') + ':/var/log/supervisor',
                   str(directory / 'state/host-policy') + ':/var/lib/remnanode', str(directory / 'state/core-manager') + ':/var/lib/remnawave/core-manager'])
        services = {main: app}
        extras = []
        if node_domain:
            domain(node_domain)
            app['volumes'].append(str(directory / 'certs') + ':/var/lib/remnacust/tls:ro')
            services['node-nginx'] = dict(common, image='nginx:1.28-alpine', network_mode='host',
                    volumes=[str(directory / 'nginx.conf') + ':/etc/nginx/conf.d/default.conf:ro',
                             str(directory / 'certs') + ':/var/lib/remnacust/tls:ro',
                             str(directory / 'run') + ':/var/lib/remnacust/run',
                             str(directory / 'www') + ':/usr/share/nginx/html:ro'])
            extras = ['node-nginx']
        result = {'name': project, 'services': services}
    state = {'schema': 1, 'component': component, 'directory': str(directory), 'project': project,
             'composeFiles': [str(directory / 'compose.json')], 'mainService': main,
             'applications': [main], 'extraServices': extras, 'nodeDomain': node_domain,
             'panelDomain': hostname if component == 'panel' else '', 'proxy': proxy,
             'apiPort': number, 'ownedServices': list(services)}
    if component == 'panel':
        state['subscriptionUrls'] = subscription_urls(subscriptions, hostname)
        if subscription_image:
            state.update({'subscriptionPage': True, 'subscriptionPort': subscription_port,
                          'subscriptionTokenUuid': str(uuid.uuid4())})
            state['applications'].append('remnawave-subscription-page')
    return result, state


def compare_environment(before, after, allow_net_admin=False):
    old, new = environment(before), environment(after)
    for key in old:
        if key.startswith(('APP_', 'JWT_', 'POSTGRES_', 'REDIS_', 'HWID_', 'METRICS_', 'WEBHOOK_')) or key in {'DATABASE_URL', 'DIRECT_URL', 'FRONT_END_DOMAIN', 'SUB_PUBLIC_DOMAIN', 'SECRET_KEY', 'NODE_PORT', 'INSTANCE_TYPE'}:
            if old[key] != new.get(key):
                fail('Изменился параметр приложения: ' + key)
    mounts = lambda c: sorted([(m.get('Type'), m.get('Source'), m.get('Destination'), m.get('RW')) for m in c.get('Mounts', [])])
    old_mounts, new_mounts = mounts(before), mounts(after)
    control = ('bind', str(Path(os.environ.get('REMNACUST_ROOT', '/opt/remnacust')).resolve() / 'control'), '/run/remnacust-control', False)
    if control not in old_mounts and control in new_mounts:
        new_mounts.remove(control)
    # Only the three installer-planned state mounts may be added. Every original
    # mount, capability, port, secret and network remains subject to comparison.
    working = (after.get('Config', {}).get('Labels') or {}).get('com.docker.compose.project.working_dir')
    if working and environment(before).get('SECRET_KEY'):
        for mount in list(new_mounts):
            if mount in old_mounts or mount[0] != 'bind' or mount[3] is not True:
                continue
            if mount[2] not in NODE_STATE_DIRECTORIES:
                continue
            source = Path(mount[1])
            relative = source.resolve().relative_to(Path(working).resolve()) if source.resolve().is_relative_to(Path(working).resolve()) else None
            if relative and len(relative.parts) == 2 and re.fullmatch(r'\.remnacust-node-state-[a-f0-9]{32}', relative.parts[0]) and relative.parts[1] == NODE_STATE_DIRECTORIES[mount[2]]:
                new_mounts.remove(mount)
    if old_mounts != new_mounts:
        fail('Изменились тома приложения')
    for name in ['NetworkMode', 'PortBindings', 'CapAdd', 'CapDrop', 'Privileged']:
        if allow_net_admin and name in ('CapAdd', 'CapDrop'):
            caps = lambda container: {str(cap).upper().removeprefix('CAP_') for cap in (container.get('HostConfig', {}).get(name) or [])}
            old_caps, new_caps = caps(before), caps(after)
            if name == 'CapAdd' and new_caps == old_caps | {'NET_ADMIN'}:
                continue
            if name == 'CapDrop' and new_caps == old_caps - {'NET_ADMIN'}:
                continue
        if before.get('HostConfig', {}).get(name) != after.get('HostConfig', {}).get(name):
            fail('Изменился HostConfig: ' + name)


NODE_STATE_DIRECTORIES = {
    '/var/lib/remnacust/run': 'runtime',
    '/var/lib/remnanode': 'host-policy',
    '/var/lib/remnawave/core-manager': 'core-manager',
}


def plan_node_state(config, container, directory):
    directory = Path(directory).resolve()
    if not directory.is_dir() or directory == Path(directory.anchor):
        fail('Не найден безопасный каталог установки ноды')
    main = (container.get('Config', {}).get('Labels') or {}).get('com.docker.compose.service')
    if main not in config.get('services', {}):
        fail('Не найдена служба ноды для сохранения состояния')
    root = directory / ('.remnacust-node-state-' + uuid.uuid4().hex)
    plan = {'container': container['Id'], 'directory': str(directory), 'root': str(root), 'copies': []}
    for target, name in NODE_STATE_DIRECTORIES.items():
        covering = [mount for mount in container.get('Mounts', []) if target == mount.get('Destination') or target.startswith(mount.get('Destination', '') + '/')]
        if covering:
            if not max(covering, key=lambda mount: len(mount['Destination'])).get('RW', True):
                fail('Каталог состояния ноды подключён только для чтения: ' + target)
            continue
        source = root / name
        config['services'][main].setdefault('volumes', []).append({'type': 'bind', 'source': str(source), 'target': target})
        plan['copies'].append({'source': target, 'target': str(source)})
    return plan


class NodeStateTarInfo(tarfile.TarInfo):
    def _bounded_metadata(self, archive):
        total = getattr(archive, '_remnacust_metadata_bytes', 0) + self.size
        if self.size > 1024**2 or total > 16 * 1024**2:
            fail('Node state archive metadata exceeds the safe limit')
        archive._remnacust_metadata_bytes = total

    def _proc_pax(self, archive):
        self._bounded_metadata(archive)
        return super()._proc_pax(archive)

    def _proc_gnulong(self, archive):
        self._bounded_metadata(archive)
        return super()._proc_gnulong(archive)

    def _proc_sparse(self, archive):
        fail('Sparse files are not supported in node state migration')


def extract_node_state_archive(stream, target, byte_limit=2 * 1024**3, entry_limit=10000):
    """Bound headers and logical data before writing into the fresh private tree."""
    target = Path(target)
    total = count = 0
    with tarfile.open(fileobj=stream, mode='r|', tarinfo=NodeStateTarInfo) as archive:
        for member in archive:
            count += 1
            parts = Path(member.name).parts
            if count > entry_limit or Path(member.name).is_absolute() or '..' in parts:
                fail('Unsafe node state archive path or entry count')
            if not member.isdir() and not member.isfile() or member.issparse():
                fail('Unsupported node state archive member')
            if member.size < 0 or member.size > byte_limit - total:
                fail('Node state exceeds the safe migration size')
            destination = target.joinpath(*parts)
            if not destination.is_relative_to(target):
                fail('Node state archive escaped its destination')
            if member.isdir():
                if member.size:
                    fail('Unexpected directory payload in node state archive')
                destination.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            total += member.size
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if shutil.disk_usage(target).free < member.size + 64 * 1024**2:
                fail('Insufficient disk headroom for safe node state migration')
            source = archive.extractfile(member)
            if source is None:
                fail('Node state archive content is missing')
            # Exclusive creation prevents duplicate members from overwriting state.
            with source, destination.open('xb') as output:
                destination.chmod(0o700 if member.mode & 0o111 else 0o600)
                remaining = member.size
                while remaining:
                    block = source.read(min(remaining, 65536))
                    if not block:
                        fail('Node state archive was truncated')
                    output.write(block)
                    remaining -= len(block)
                output.flush()
                os.fsync(output.fileno())
    return count


def copy_node_state_archive(container, source, target):
    args = ['docker', 'cp', container + ':' + source + '/.', '-']
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    timer = threading.Timer(180, process.kill)
    timer.daemon = True
    timer.start()
    error = None
    try:
        try:
            extract_node_state_archive(process.stdout, target)
        except Exception as failure:
            error = failure
            process.kill()
        process.stdout.close()
        diagnostics = process.stderr.read(16384).decode('utf-8', errors='replace')
        process.stderr.close()
        result = process.wait(timeout=20)
        missing = 'Could not find the file ' in diagnostics and source in diagnostics
        if error is not None and not missing:
            raise ConfigurationError('Cannot safely copy node state; original container preserved') from error
        return subprocess.CompletedProcess(args, result, '', diagnostics)
    finally:
        timer.cancel()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=20)


def snapshot_node_state(plan, run=subprocess.run, copy_state=copy_node_state_archive):
    if not plan['copies']:
        return
    # A stopped source makes state.json, selected binaries and quota receipts a
    # coherent snapshot. Rollback keeps the original container layer untouched.
    inspected = run(['docker', 'inspect', plan['container']], check=True, capture_output=True, text=True, timeout=20)
    container = json.loads(inspected.stdout)[0]
    if container.get('Id') != plan['container'] or container.get('State', {}).get('Running'):
        fail('Перед переносом состояния остановите исходную ноду')
    directory = Path(plan['directory']).resolve()
    root = Path(plan['root'])
    if root.is_symlink() or root.parent.resolve() != directory or not re.fullmatch(r'\.remnacust-node-state-[a-f0-9]{32}', root.name):
        fail('Некорректный каталог переноса состояния ноды')
    root.mkdir(mode=0o700, exist_ok=False)
    for item in plan['copies']:
        source, target = item['source'], Path(item['target'])
        if source not in NODE_STATE_DIRECTORIES or target != root / NODE_STATE_DIRECTORIES[source]:
            fail('Некорректный путь состояния ноды')
        target.mkdir(mode=0o700)
        copied = copy_state(plan['container'], source, target)
        if copied.returncode:
            # Docker's archive endpoint distinguishes an absent legacy state
            # directory from daemon/permission/disk failures. Never swallow the latter.
            if 'Could not find the file ' not in copied.stderr or source not in copied.stderr:
                fail('Не удалось сохранить состояние ноды; прежний контейнер не изменён')
        total = count = 0
        for path in [target, *target.rglob('*')]:
            info = path.lstat()
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                fail('Неподдерживаемый тип файла в состоянии ноды')
            count += 1
            total += info.st_size if path.is_file() else 0
            if count > 10000 or total > 2 * 1024**3:
                fail('Состояние ноды превышает безопасный размер переноса')
            path.chmod(0o700 if path.is_dir() or info.st_mode & 0o111 else 0o600)
    core = next((Path(item['target']) for item in plan['copies'] if item['source'] == '/var/lib/remnawave/core-manager'), None)
    if core and (core / 'state.json').exists():
        state = load(core / 'state.json')
        for selection in [state, state.get('previous'), state.get('recovery')]:
            binary = (selection or {}).get('binary')
            if not binary:
                continue
            binary_path = binary.get('path', '')
            digest = binary.get('sha256', '')
            if not re.fullmatch(r'[a-f0-9]{64}', digest):
                fail('Некорректная контрольная сумма выбранного ядра')
            if binary_path == '/usr/local/bin/xray' and selection.get('mode') == 'bundled':
                continue
            if binary_path != '/var/lib/remnawave/core-manager/' + digest:
                fail('Выбранное ядро находится вне сохраняемого каталога; сначала выберите управляемое или встроенное ядро')
            if not (core / digest).is_file() or file_sha256(core / digest) != digest:
                fail('Не удалось проверить сохранённый бинарный файл ядра')


    if os.name != 'nt':
        # A flushed file is insufficient if a power loss can discard its new
        # parent directory. Publish the whole snapshot before any replacement.
        directories = [directory, root, *(path for path in root.rglob('*') if path.is_dir())]
        for path in sorted(directories, key=lambda value: len(value.parts), reverse=True):
            descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['discover', 'transform', 'panel-env', 'node-env', 'node-proxy', 'fresh', 'compare', 'validate', 'get', 'record', 'hash-backup', 'verify-backup', 'subscription-urls', 'subscription-domains', 'subscription-env', 'commit-compose', 'restore-compose', 'database-network', 'plan-node-state', 'snapshot-node-state', 'preserve-node-state-rollback', 'plan-panel-data-restore', 'validate-panel-data-restore', 'commit-panel-data-restore', 'restore-panel-subscription-token', 'node-capability'])
    parser.add_argument('--source'); parser.add_argument('--target'); parser.add_argument('--inspect')
    parser.add_argument('--component', choices=['panel', 'node']); parser.add_argument('--directory')
    parser.add_argument('--project'); parser.add_argument('--image'); parser.add_argument('--state'); parser.add_argument('--compose-file')
    parser.add_argument('--roles'); parser.add_argument('--running', nargs='*')
    parser.add_argument('--plan'); parser.add_argument('--current-inspect'); parser.add_argument('--environment-source')
    parser.add_argument('--network', default='')
    parser.add_argument('--panel-net-admin', action='store_true')
    parser.add_argument('--node-no-net-admin', action='store_true')
    parser.add_argument('--domain', default=''); parser.add_argument('--port', default='3000')
    parser.add_argument('--subscription-urls', default='')
    parser.add_argument('--subscription-image', default=''); parser.add_argument('--subscription-port', default='3010')
    parser.add_argument('--proxy', choices=['caddy', 'existing'], default='caddy')
    parser.add_argument('--node-domain', default=''); parser.add_argument('--key'); parser.add_argument('--version')
    args = parser.parse_args()
    if args.operation == 'node-capability':
        config = load(args.source)
        service = config['services'][load(args.state)['mainService']]
        enabled = any(str(cap).upper().removeprefix('CAP_') in ('NET_ADMIN', 'ALL') for cap in service.get('cap_add', [])) or service.get('privileged') is True
        if args.key == 'enable' and not enabled:
            service.setdefault('cap_add', []).append('NET_ADMIN')
            service['cap_drop'] = [cap for cap in service.get('cap_drop', []) if str(cap).upper().removeprefix('CAP_') != 'NET_ADMIN']
            write(args.source, config)
            enabled = True
        print('yes' if enabled else 'no')
    elif args.operation == 'hash-backup':
        backup_hashes(args.directory)
    elif args.operation == 'plan-node-state':
        config = load(args.source)
        plan = plan_node_state(config, inspect_one(args.inspect), args.directory)
        write(args.source, config)
        write(args.target, plan)
    elif args.operation == 'snapshot-node-state':
        snapshot_node_state(load(args.source))
    elif args.operation == 'preserve-node-state-rollback':
        preserve_node_state_rollback(args.source, args.directory)
    elif args.operation == 'commit-compose':
        commit_compose(args.state, args.source, args.directory, args.version, args.key)
    elif args.operation == 'restore-compose':
        restore_compose(args.directory)
    elif args.operation == 'plan-panel-data-restore':
        backup = Path(args.directory)
        plan = plan_panel_data_restore(load(args.source), load(args.state), load(backup / 'state.before.json'),
            inspect_one(backup / 'container.before.json'), args.image,
            load(args.roles), inspect_one(args.current_inspect), load(args.environment_source))
        for path in [backup / 'state.before.json', backup / 'container.before.json']:
            plan['inputs'].append({'path': str(path), 'sha256': file_sha256(path)})
        write(args.plan, plan)
        write(args.target, plan['config'])
    elif args.operation == 'validate-panel-data-restore':
        validate_panel_data_restore(load(args.source))
    elif args.operation == 'commit-panel-data-restore':
        commit_panel_data_restore(load(args.source), args.state)
    elif args.operation == 'restore-panel-subscription-token':
        restore_panel_subscription_token(load(args.plan), Path(args.source).read_text(encoding='utf-8').strip())
    elif args.operation == 'verify-backup':
        verify_backup(args.directory)
    elif args.operation == 'discover':
        write(args.target, discover(inspect_one(args.inspect), args.component, args.directory, args.compose_file))
    elif args.operation == 'database-network':
        write(args.target, database_network(inspect_one(args.inspect), load(args.roles), args.network))
    elif args.operation == 'transform':
        config, apps = transform(load(args.source), inspect_one(args.inspect), args.component, args.image, load(args.roles) if args.roles else (), args.subscription_image)
        write(args.target, config)
        state = load(args.state); state['applications'] = apps; state['composeFiles'] = [str(Path(args.target).resolve())]
        write(args.state, state)
    elif args.operation == 'panel-env':
        write(args.target, panel_env(Path(args.source).read_text(), args.domain, args.port, args.subscription_urls))
    elif args.operation == 'subscription-urls':
        print('\n'.join(subscription_urls(args.subscription_urls, args.domain)))
    elif args.operation == 'subscription-domains':
        print('\n'.join(subscription_domains(args.subscription_urls, args.domain)))
    elif args.operation == 'subscription-env':
        write(args.target, subscription_env(Path(args.source).read_text().strip()))
    elif args.operation == 'node-env':
        write(args.target, node_env(os.environ.get('REMNACUST_NODE_SECRET', ''), args.port))
    elif args.operation == 'node-proxy':
        p = Path(args.directory)
        for name in ['run', 'www']:
            (p/name).mkdir(exist_ok=True); (p/name).chmod(0o755)
        write(p/'nginx.conf', nginx_config(args.domain))
        write(p/'www/index.html', '<!doctype html><html lang="en"><meta charset="utf-8"><title>Service</title><p>Service is available.</p></html>\n', mode=0o644)
    elif args.operation == 'fresh':
        config, state = fresh(args.component, args.directory, args.project, args.image, args.domain, args.port, args.proxy, args.node_domain, args.subscription_urls, args.subscription_image, args.subscription_port, args.panel_net_admin, not args.node_no_net_admin)
        write(args.target, config); write(args.state, state)
    elif args.operation == 'compare':
        compare_environment(inspect_one(args.source), inspect_one(args.inspect), args.key == 'net-admin-added')
        print('Секреты, порты и тома приложения сохранены')
    elif args.operation == 'validate':
        if args.domain: domain(args.domain)
        if args.node_domain: domain(args.node_domain)
        if args.port: port(args.port)
        if args.project: project_name(args.project)
        if args.key: ipaddress.ip_network(args.key, strict=False)
    elif args.operation == 'get':
        value = load(args.state)[args.key]
        if isinstance(value, list):
            if value:
                print('\n'.join(str(v) for v in value))
        else:
            print(value)
    elif args.operation == 'record':
        state = load(args.state)
        state.update({'version': args.version, 'image': args.image})
        if args.running is not None:
            state['runningApplications'] = args.running
        write(args.state, state)


if __name__ == '__main__':
    try:
        main()
    except ConfigurationError as error:
        import sys
        print('Ошибка конфигурации установщика: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError):
        # Inputs may include node secrets: never print rejected values or full JSON.
        import sys
        print('Ошибка конфигурации установщика. Проверьте путь, Compose, исходные секреты и параметры.', file=sys.stderr)
        raise SystemExit(1)
