#!/usr/bin/env python3
"""Move an owned deployment to its canonical path without changing Docker data."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime
from subscription_migration import command, compose_base


def mapped(value, old, new):
    if isinstance(value, str):
        return str(new) + value[len(str(old)):] if value == str(old) or value.startswith(str(old) + '/') else value
    if isinstance(value, list):
        return [mapped(item, old, new) for item in value]
    if isinstance(value, dict):
        return {key: mapped(item, old, new) for key, item in value.items()}
    return value


def compose_paths(config, old, new):
    result = copy.deepcopy(config)
    for service in result.get('services', {}).values():
        service['env_file'] = mapped(service['env_file'], old, new) if 'env_file' in service else []
        for volume in service.get('volumes', []):
            if isinstance(volume, dict) and volume.get('type') == 'bind':
                volume['source'] = mapped(volume['source'], old, new)
        for name in ('configs', 'secrets'):
            # Service references name objects, not host paths; their declarations are below.
            for value in service.get(name, []):
                if isinstance(value, dict) and 'file' in value:
                    value['file'] = mapped(value['file'], old, new)
    for group in ('configs', 'secrets'):
        for value in result.get(group, {}).values():
            if isinstance(value, dict) and 'file' in value:
                value['file'] = mapped(value['file'], old, new)
    for volume in result.get('volumes', {}).values():
        if isinstance(volume, dict) and 'device' in volume.get('driver_opts', {}):
            volume['driver_opts']['device'] = mapped(volume['driver_opts']['device'], old, new)
    return result


def inventory():
    ids = command(['docker'], 'ps', '--all', '--quiet').split()
    if not ids:
        return []
    return json.loads(command(['docker'], 'inspect', *ids))


def referenced(path, containers, except_project=None):
    for container in containers:
        labels = container.get('Config', {}).get('Labels') or {}
        if except_project and labels.get('com.docker.compose.project') == except_project:
            continue
        paths = [labels.get('com.docker.compose.project.working_dir', ''),
                 *labels.get('com.docker.compose.project.config_files', '').split(','),
                 *[mount.get('Source', '') for mount in container.get('Mounts', [])]]
        if any(value == str(path) or value.startswith(str(path) + '/') for value in paths):
            return True
    return False


def wait_services(base, names, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ids = command(base, 'ps', '--all', '--quiet', *names).split()
        current = json.loads(command(['docker'], 'inspect', *ids)) if ids else []
        if len(current) == len(names) and all(c.get('State', {}).get('Running') and c.get('State', {}).get('Health', {}).get('Status') in (None, 'healthy') for c in current):
            return current
        if any(c.get('State', {}).get('Health', {}).get('Status') == 'unhealthy' for c in current):
            break
        time.sleep(2)
    raise ValueError('CANONICAL_LAYOUT_NOT_READY')


def archive_unused(root, component, containers):
    for path in sorted(root.glob(component + '-*')):
        if not re.fullmatch(re.escape(component) + r'-\d{14}-\d+', path.name) or path.is_symlink() or not path.is_dir() or referenced(path, containers):
            continue
        archive = root / 'backups/retired-layout' / path.name
        archive.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if archive.exists():
            archive = archive.with_name(archive.name + '-' + uuid.uuid4().hex[:8])
        path.rename(archive)


def normalize(root, component):
    if component not in ('panel', 'node'):
        raise ValueError('INVALID_COMPONENT')
    root = root.resolve()
    record = root / 'registry' / (component + '.json')
    state = runtime.load(record)
    if state.get('component') != component or state.get('uninstalled'):
        raise ValueError('COMPONENT_NOT_INSTALLED')
    old, target = Path(state['directory']), root / component
    containers = inventory()
    if old == target:
        archive_unused(root, component, containers)
        return state
    if old.parent != root or old.is_symlink() or not re.fullmatch(re.escape(component) + r'-\d{14}-\d+', old.name):
        # Explicit external/custom deployments are not silently moved.
        return state
    if not old.is_dir() or target.is_symlink() or old.stat().st_dev != root.stat().st_dev:
        raise ValueError('UNSAFE_CANONICAL_PATH')
    if referenced(old, containers, state['project']) or (target.exists() and referenced(target, containers)):
        raise ValueError('LAYOUT_DIRECTORY_IN_USE')
    if target.exists() and not target.is_dir():
        raise ValueError('CANONICAL_TARGET_NOT_DIRECTORY')
    project = [c for c in containers if (c.get('Config', {}).get('Labels') or {}).get('com.docker.compose.project') == state['project']]
    by_service = {(c.get('Config', {}).get('Labels') or {}).get('com.docker.compose.service'): c for c in project}
    if not project or len(project) != len(by_service) or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name or '') for name in by_service):
        raise ValueError('INVALID_PROJECT_INVENTORY')
    base = compose_base(state)
    before = json.loads(command(base, '--profile', '*', 'config', '--no-interpolate', '--no-env-resolution', '--format', 'json'))
    if not set(by_service) <= set(before.get('services', {})):
        raise ValueError('UNREGISTERED_PROJECT_SERVICE')
    after = compose_paths(before, old, target)
    updated = mapped(state, old, target)
    updated['composeFiles'] = [str(target / 'docker-compose.yml')]
    updated['composeEntryPoint'] = updated['composeFiles'][0]
    running = [name for name, c in by_service.items() if c.get('State', {}).get('Running')]
    stopped = [name for name in by_service if name not in running]
    backup = root / 'backups' / ('layout-' + component + '-' + uuid.uuid4().hex)
    backup.mkdir(mode=0o700, parents=True)
    runtime.write(backup / 'registry.before.json', state)
    runtime.write(backup / 'compose.before.json', before)
    runtime.write(backup / 'plan.json', {'from': str(old), 'to': str(target), 'running': running, 'stopped': stopped})
    originals = {}
    for value in state['composeFiles']:
        path = runtime.compose_path(old, value)
        originals[str(path.relative_to(old))] = (path.read_text(), path.stat().st_mode & 0o777)
    # Default overlays must not override the new canonical entry point.
    for path in runtime.neutral_compose_overrides(old, [Path(p) for p in state['composeFiles']]):
        originals[str(path.relative_to(old))] = (path.read_text(), path.stat().st_mode & 0o777)
    runtime.write(backup / 'files.before.json', originals)
    registry_before = {}
    for path in (root / 'registry').rglob('*.json'):
        if path.is_symlink():
            raise ValueError('UNSAFE_REGISTRY')
        value = runtime.load(path)
        next_value = mapped(value, old, target)
        if next_value != value:
            registry_before[str(path.relative_to(root))] = value
    moved = False
    created_records = []
    archived_target = backup / 'previous-directory'
    try:
        command(base, 'stop', '--timeout', '30', *by_service)
        if target.exists():
            target.rename(archived_target)
        old.rename(target)
        moved = True
        for name in originals:
            path = target / name
            if path.exists():
                path.unlink()
        runtime.write(target / 'docker-compose.yml', after)
        new_base = compose_base(updated)
        command(new_base, '--profile', '*', 'config', '--quiet')
        if stopped:
            command(new_base, 'up', '--no-deps', '--no-build', '--pull', 'never', '--no-start', *stopped)
        if running:
            command(new_base, 'up', '-d', '--force-recreate', '--no-deps', '--no-build', '--pull', 'never', *running)
            current = wait_services(new_base, running)
            for container in current:
                name = (container['Config'].get('Labels') or {})['com.docker.compose.service']
                original = by_service[name]
                if sorted(container['Config'].get('Env') or []) != sorted(original['Config'].get('Env') or []) or container['Image'] != original['Image']:
                    raise ValueError('CONTAINER_IDENTITY_CHANGED')
                old_volumes = sorted((m.get('Name'), m.get('Destination')) for m in original.get('Mounts', []) if m.get('Type') == 'volume')
                new_volumes = sorted((m.get('Name'), m.get('Destination')) for m in container.get('Mounts', []) if m.get('Type') == 'volume')
                if old_volumes != new_volumes:
                    raise ValueError('DOCKER_VOLUME_IDENTITY_CHANGED')
                if name == state['mainService']:
                    updated['container'] = container['Id']
        for relative, value in registry_before.items():
            path = root / relative
            next_value = mapped(value, old, target)
            if relative.startswith('registry/subscription-pages/'):
                from subscription_pages import identity
                next_path = path.with_name(identity(next_value) + '.json')
                runtime.write(next_path, next_value)
                if next_path != path:
                    created_records.append(next_path)
                    path.unlink()
            else:
                runtime.write(path, next_value)
        runtime.write(record, updated)
        runtime.write_layout(updated, after)
    except BaseException:
        if moved:
            try:
                command(compose_base(updated), 'stop', '--timeout', '30', *by_service)
            finally:
                canonical = target / 'docker-compose.yml'
                if canonical.exists():
                    canonical.unlink()
                for name, (text, mode) in originals.items():
                    runtime.write(target / name, text, mode)
                target.rename(old)
        if archived_target.exists():
            archived_target.rename(target)
        for relative, value in registry_before.items():
            runtime.write(root / relative, value)
        for path in created_records:
            if path.exists():
                path.unlink()
        runtime.write(record, state)
        if stopped:
            command(base, 'up', '--no-start', '--no-deps', '--no-build', '--pull', 'never', *stopped)
        if running:
            command(base, 'up', '-d', '--force-recreate', '--no-deps', '--no-build', '--pull', 'never', *running)
            wait_services(base, running)
        raise
    archive_unused(root, component, inventory())
    return updated


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--component', choices=['panel', 'node'], required=True)
    args = parser.parse_args()
    try:
        result = normalize(args.root, args.component)
        print('Рабочий каталог: ' + result['directory'])
    except (ValueError, OSError, KeyError):
        raise SystemExit('Перенос в постоянный каталог не завершён. Исходные настройки восстановлены; проверьте приватный журнал.')
