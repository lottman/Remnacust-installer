#!/usr/bin/env python3
"""Opt-in upgrade of an existing subscription page, preserving its deployment."""
import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime


def descriptor(container):
    labels = container.get('Config', {}).get('Labels') or {}
    directory = labels.get('com.docker.compose.project.working_dir', '')
    project = labels.get('com.docker.compose.project', '')
    service = labels.get('com.docker.compose.service', '')
    if not directory.startswith('/') or directory == '/' or any(ord(char) < 32 or ord(char) == 127 for char in directory) or not project or not service:
        return None
    runtime.project_name(project)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', service):
        return None
    files = labels.get('com.docker.compose.project.config_files', '').split(',')
    if not 1 <= len(files) <= 32 or not all(files):
        return None
    return dict(directory=directory, project=project, service=service,
                composeFiles=files, tokenUuid=str(uuid.uuid4()))


def candidates(panel, containers):
    env = runtime.environment(panel)
    names = {'remnawave', 'remnacust', (panel.get('Config', {}).get('Labels') or {}).get('com.docker.compose.service')}
    for key in ['PANEL_DOMAIN', 'FRONT_END_DOMAIN']:
        if env.get(key):
            names.add(urlsplit(env[key] if '://' in env[key] else 'https://' + env[key]).hostname)
    networks = set(panel.get('NetworkSettings', {}).get('Networks') or {})
    result = []
    seen = set()
    for container in containers:
        settings = runtime.environment(container)
        repository = container.get('Config', {}).get('Image', '').split('@')[0].rsplit('/', 1)[-1].split(':')[0]
        if repository not in {'subscription-page', 'remnacust-subscription-page'}:
            continue
        endpoint = urlsplit(settings.get('REMNAWAVE_PANEL_URL', ''))
        if endpoint.scheme not in {'http', 'https'} or endpoint.hostname not in names:
            continue
        if endpoint.hostname in {'remnawave', 'remnacust'} and not networks.intersection(container.get('NetworkSettings', {}).get('Networks') or {}):
            continue
        item = descriptor(container)
        key = (item['directory'], item['project'], item['service']) if item else None
        if item and key not in seen:
            seen.add(key)
            result.append(item)
    return sorted(result, key=lambda item: (item['project'], item['service']))


def command(base, *args, run=subprocess.run):
    result = run([*base, *args], text=True, capture_output=True, timeout=180)
    if result.returncode:
        raise runtime.ConfigurationError('Команда Docker для страницы подписки не завершилась; секретный вывод скрыт')
    return result.stdout


def compose_base(item, files=None):
    directory = Path(item['directory']).resolve()
    if not directory.is_dir() or directory == Path(directory.anchor):
        runtime.fail('Каталог страницы подписки недоступен')
    files = [runtime.compose_path(directory, value) for value in (files or item['composeFiles'])]
    if not files or not all(path.is_file() for path in files):
        runtime.fail('Исходный Compose страницы подписки недоступен')
    return ['docker', 'compose', '--project-name', runtime.project_name(item['project']),
            '--project-directory', str(directory), *[arg for file in files for arg in ['-f', str(file)]]]


def upgrade(state_path, image, token_path, backup_root, version, release, run=subprocess.run, sleep=time.sleep):
    state = runtime.load(state_path)
    item = state['subscriptionMigration']
    if state['directory'] == item['directory'] and state['project'] == item['project']:
        item['composeFiles'] = state['composeFiles']
    base = compose_base(item)
    config = json.loads(command(base, '--profile', '*', 'config', '--no-interpolate', '--no-env-resolution', '--format', 'json', run=run))
    service = item['service']
    if service not in config.get('services', {}):
        runtime.fail('Выбранная страница подписки отсутствует в Compose')
    token = Path(token_path).read_text().strip()
    runtime.subscription_env(token)
    before = copy.deepcopy(config)
    settings = config['services'][service]
    settings['image'] = image
    settings.pop('build', None)
    settings['environment'] = {**runtime.compose_environment(settings.get('environment')), 'REMNAWAVE_API_TOKEN': token}
    settings['labels'] = {**(settings.get('labels') or {}), 'io.remnacust.service-role': 'subscription-page'}
    backup = Path(backup_root) / ('subscription-page-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700, parents=True)
    local = backup / 'state.json'
    snapshot = {**item, 'component': 'subscription-page', 'mainService': service, 'applications': [service]}
    runtime.write(local, snapshot)
    runtime.write(backup / 'state.before.json', snapshot)
    runtime.write(backup / 'compose.before.json', before)
    candidate = backup / 'candidate.json'
    runtime.write(candidate, config)
    was_running = False
    container_id = command(base, 'ps', '--all', '--quiet', service, run=run).strip()
    if container_id:
        current = json.loads(command(['docker'], 'inspect', container_id, run=run))[0]
        was_running = current.get('State', {}).get('Running', False)
    try:
        command(['docker', 'compose', '--project-name', item['project'], '--project-directory', item['directory'], '-f', str(candidate)], '--profile', '*', 'config', '--quiet', run=run)
        runtime.commit_compose(local, candidate, backup, version, release)
        active = compose_base(item, runtime.load(local)['composeFiles'])
        # Stopped pages stay stopped. A running page is recreated without touching its proxy or DB.
        command(active, 'up', '--no-deps', '--no-build', '--pull', 'never', *(['-d'] if was_running else ['--no-start']), service, run=run)
        if was_running:
            for _ in range(60):
                container_id = command(active, 'ps', '--all', '--quiet', service, run=run).strip()
                current = json.loads(command(['docker'], 'inspect', container_id, run=run))[0] if container_id else {}
                health = current.get('State', {}).get('Health', {}).get('Status')
                if current.get('State', {}).get('Running') and health in {None, 'healthy'}:
                    if current.get('Config', {}).get('Image') != image or runtime.environment(current).get('REMNAWAVE_API_TOKEN') != token:
                        runtime.fail('Не подтверждены новый образ и ограниченный токен страницы подписки')
                    break
                if health == 'unhealthy' or current.get('State', {}).get('Status') in {'dead', 'exited'}:
                    runtime.fail('Страница подписки не прошла проверку готовности')
                sleep(2)
            else:
                runtime.fail('Истекло время ожидания страницы подписки')
        item['composeFiles'] = runtime.load(local)['composeFiles']
        runtime.write_layout(state if state['directory'] == item['directory'] and state['project'] == item['project'] else {**snapshot, 'composeFiles': item['composeFiles']}, config)
        runtime.write(state_path, state)
    except Exception:
        runtime.restore_compose(backup)
        command(base, 'up', '--no-deps', '--no-build', '--pull', 'never', *(['-d'] if was_running else ['--no-start']), service, run=run)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['discover', 'select', 'upgrade'])
    for field in ['panel', 'containers', 'output', 'state', 'source', 'image', 'token', 'backup-root', 'version', 'release']:
        parser.add_argument('--' + field)
    parser.add_argument('--index', type=int)
    args = parser.parse_args()
    if args.operation == 'discover':
        runtime.write(args.output, candidates(runtime.load(args.panel)[0], runtime.load(args.containers)))
    elif args.operation == 'select':
        choices = runtime.load(args.source)
        if args.index is None or not 0 <= args.index < len(choices):
            runtime.fail('Некорректный номер страницы подписки')
        state = runtime.load(args.state)
        state['subscriptionMigration'] = choices[args.index]
        runtime.write(args.state, state)
    else:
        upgrade(args.state, args.image, args.token, args.backup_root, args.version, args.release)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print('Перенос страницы подписки не завершён; проверьте Compose, сеть и состояние контейнера. Настройки восстановлены, если началось применение.', file=sys.stderr)
        sys.exit(1)
