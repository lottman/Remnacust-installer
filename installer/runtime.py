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
import tempfile


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
    finally:
        if os.path.exists(name):
            os.unlink(name)


def domain(value):
    if len(value) > 253 or not re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', value):
        fail('Укажите домен без протокола, порта и пути')
    return value.lower()


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


def verify_backup(directory):
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
    required = {'database.dump', 'container.before.json', 'state.before.json', 'env-files.json', 'compose.before.json'}
    if not required <= names:
        fail('Неполная резервная копия панели')
    state = load(root/'state.before.json')
    required.update('original-'+str(i) for i in range(len(state['composeFiles'])))
    required.update(load(root/'env-files.json').values())
    required.update(name for name in ['environment.before', 'fingerprints.json'] if (root/name).exists())
    if not required <= names:
        fail('Файл конфигурации не подтверждён контрольной суммой')


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


def transform(config, container, component, image, containers=()):
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


def panel_env(template, hostname, host_port):
    hostname = domain(hostname)
    password = secrets.token_hex(32)
    values = {'APP_SECRET': secrets.token_hex(32), 'POSTGRES_PASSWORD': password,
              'POSTGRES_USER': 'postgres', 'POSTGRES_DB': 'postgres',
              'DATABASE_URL': f'postgresql://postgres:{password}@remnawave-db:5432/postgres',
              'FRONT_END_DOMAIN': 'https://' + hostname, 'PANEL_DOMAIN': hostname,
              'SUB_PUBLIC_DOMAIN': hostname + '/api/sub', 'HWID_ENABLED_DEFAULT': 'true',
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


def fresh(component, directory, project, image, hostname='', number='3000', proxy='caddy', node_domain=''):
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
        database = dict(common, image='postgres:18.4', env_file=[str(directory / '.env')],
                        shm_size='512mb', environment={'TZ': 'UTC'}, volumes=['database:/var/lib/postgresql'],
                        healthcheck={'test': ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}'], 'interval': '3s', 'timeout': '5s', 'retries': 20})
        redis = dict(common, image='valkey/valkey:9-alpine', volumes=['valkey-socket:/var/run/valkey'],
                     command=['valkey-server', '--save', '', '--appendonly', 'no', '--maxmemory-policy', 'noeviction', '--unixsocket', '/var/run/valkey/valkey.sock', '--unixsocketperm', '777', '--port', '0'],
                     healthcheck={'test': ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping'], 'interval': '3s', 'timeout': '5s', 'retries': 20})
        services = {'remnawave': app, 'remnawave-db': database, 'remnawave-redis': redis}
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
                   cap_add=['NET_ADMIN'], volumes=[str(directory / 'run') + ':/var/lib/remnacust/run', str(directory / 'logs') + ':/var/log/supervisor'])
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
    return result, state


def compare_environment(before, after):
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
    if old_mounts != new_mounts:
        fail('Изменились тома приложения')
    for name in ['NetworkMode', 'PortBindings', 'CapAdd', 'CapDrop', 'Privileged']:
        if before.get('HostConfig', {}).get(name) != after.get('HostConfig', {}).get(name):
            fail('Изменился HostConfig: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['discover', 'transform', 'panel-env', 'node-env', 'node-proxy', 'fresh', 'compare', 'validate', 'get', 'record', 'hash-backup', 'verify-backup'])
    parser.add_argument('--source'); parser.add_argument('--target'); parser.add_argument('--inspect')
    parser.add_argument('--component', choices=['panel', 'node']); parser.add_argument('--directory')
    parser.add_argument('--project'); parser.add_argument('--image'); parser.add_argument('--state'); parser.add_argument('--compose-file')
    parser.add_argument('--roles'); parser.add_argument('--running', nargs='*')
    parser.add_argument('--domain', default=''); parser.add_argument('--port', default='3000')
    parser.add_argument('--proxy', choices=['caddy', 'existing'], default='caddy')
    parser.add_argument('--node-domain', default=''); parser.add_argument('--key'); parser.add_argument('--version')
    args = parser.parse_args()
    if args.operation == 'hash-backup':
        backup_hashes(args.directory)
    elif args.operation == 'verify-backup':
        verify_backup(args.directory)
    elif args.operation == 'discover':
        write(args.target, discover(inspect_one(args.inspect), args.component, args.directory, args.compose_file))
    elif args.operation == 'transform':
        config, apps = transform(load(args.source), inspect_one(args.inspect), args.component, args.image, load(args.roles) if args.roles else ())
        write(args.target, config)
        state = load(args.state); state['applications'] = apps; state['composeFiles'] = [str(Path(args.target).resolve())]
        write(args.state, state)
    elif args.operation == 'panel-env':
        write(args.target, panel_env(Path(args.source).read_text(), args.domain, args.port))
    elif args.operation == 'node-env':
        write(args.target, node_env(os.environ.get('REMNACUST_NODE_SECRET', ''), args.port))
    elif args.operation == 'node-proxy':
        p = Path(args.directory)
        for name in ['run', 'www']:
            (p/name).mkdir(exist_ok=True); (p/name).chmod(0o755)
        write(p/'nginx.conf', nginx_config(args.domain))
        write(p/'www/index.html', '<!doctype html><html lang="en"><meta charset="utf-8"><title>Service</title><p>Service is available.</p></html>\n', mode=0o644)
    elif args.operation == 'fresh':
        config, state = fresh(args.component, args.directory, args.project, args.image, args.domain, args.port, args.proxy, args.node_domain)
        write(args.target, config); write(args.state, state)
    elif args.operation == 'compare':
        compare_environment(inspect_one(args.source), inspect_one(args.inspect))
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
