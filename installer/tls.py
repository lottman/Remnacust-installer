"""Certificate validation and configuration for new Remnacust installations."""
import argparse
import configparser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from runtime import domain, subscription_domains, write


def openssl(*args, data=None):
    result = subprocess.run(['openssl', *args], input=data, capture_output=True, timeout=15)
    if result.returncode:
        raise ValueError('Некорректный PEM, зашифрованный ключ или ошибка проверки сертификата')
    return result.stdout


def certificate_pair(hostname, certificate, key, subscriptions=''):
    domain(hostname)
    cert, private = Path(certificate), Path(key)
    for p in (cert, private):
        if any(c in str(p) for c in '\n\r\0'):
            raise ValueError('В пути PEM не должно быть управляющих символов')
        if not p.is_file() or p.stat().st_size > 1024 * 1024:
            raise ValueError('Сертификат и ключ должны быть PEM-файлами не больше 1 MiB')
    # Read once so validation and subsequent copying use exactly the same pair.
    cert_data, key_data = cert.read_bytes(), private.read_bytes()
    openssl('x509', '-noout', '-checkend', '86400', data=cert_data)
    # OpenSSL checkhost prints a mismatch but can return success: inspect its result too.
    if b'does match certificate' not in openssl('x509', '-noout', '-checkhost', hostname, data=cert_data):
        raise ValueError('Сертификат выдан для другого домена')
    for host in subscription_domains(subscriptions, hostname) if subscriptions else []:
        if b'does match certificate' not in openssl('x509', '-noout', '-checkhost', host, data=cert_data):
            raise ValueError('Сертификат должен покрывать все домены сайта подписки')
    import ssl
    from datetime import datetime, timezone
    # x509 supports both RSA and ECDSA; do not compare RSA moduli only.
    cert_public = openssl('x509', '-pubkey', '-noout', data=cert_data)
    private_public = openssl('pkey', '-pubout', '-passin', 'pass:', data=key_data)
    if cert_public != private_public:
        raise ValueError('Приватный ключ не соответствует сертификату')
    dates = openssl('x509', '-noout', '-startdate', data=cert_data).decode().strip()
    if ssl.cert_time_to_seconds(dates.split('=', 1)[1]) > datetime.now(timezone.utc).timestamp():
        raise ValueError('Срок действия сертификата ещё не начался')
    return cert_data, key_data


def copy_pair(hostname, certificate, key, directory, subscriptions=''):
    data = certificate_pair(hostname, certificate, key, subscriptions)
    destination = Path(directory)/'certs'
    if destination.is_symlink():
        raise ValueError('Каталог certs не должен быть символьной ссылкой')
    destination.mkdir(mode=0o700, exist_ok=True)
    destination.chmod(0o700)
    names = ('fullchain.pem', 'privkey.pem')
    old = []
    for name in names:
        p = destination/name
        if p.is_symlink():
            raise ValueError('Целевые PEM-файлы не должны быть символьными ссылками')
        old.append(p.read_bytes() if p.exists() else None)
    try:
        for name, content in zip(names, data):
            atomic_bytes(destination/name, content)
    except OSError:
        for name, content in zip(names, old):
            p = destination/name
            if content is None:
                p.unlink(missing_ok=True)
            else:
                atomic_bytes(p, content)
        raise


def atomic_bytes(path, content):
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix='.tls-')
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def credentials(method, source, target):
    path = Path(source)
    if not path.is_file() or path.stat().st_size > 16384 or path.stat().st_mode & 0o077:
        raise ValueError('DNS credentials: нужен небольшой INI-файл с правами 600')
    config = configparser.ConfigParser(interpolation=None)
    config.read_string('[dns]\n'+path.read_text())
    fields = dict(config['dns'])
    permitted = ({'dns_cloudflare_api_token'} if method == 'cloudflare' else {'dns_gcore_apitoken'})
    if method == 'cloudflare' and set(fields) == {'dns_cloudflare_email', 'dns_cloudflare_api_key'}:
        permitted = set(fields)
    if set(fields) != permitted or any(not v or '\n' in v or '\r' in v for v in fields.values()):
        raise ValueError('В INI нет нужных полей выбранного DNS-провайдера')
    target = Path(target)
    if target.is_symlink():
        raise ValueError('Небезопасный путь credentials')
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    atomic_bytes(target, ''.join(f'{k} = {v}\n' for k, v in fields.items()).encode())


def caddy(hostname, email, method, directory, subscriptions=''):
    domain(hostname)
    if method == 'auto':
        if email and not re.fullmatch(r'[A-Za-z0-9_.+\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', email):
            raise ValueError('Некорректный email')
        header = '{\n    email '+email+'\n}\n\n' if email else ''
        tls = ''
    else:
        header = ''
        tls = '    tls /var/lib/remnacust/tls/fullchain.pem /var/lib/remnacust/tls/privkey.pem\n'
    config = header+hostname+' {\n'+tls+'    reverse_proxy remnawave:3000\n}\n'
    if subscriptions:
        hosts = subscription_domains(subscriptions, hostname)
        config += '\n'+', '.join(hosts)+' {\n'+tls+'    reverse_proxy remnawave-subscription-page:3010\n}\n'
    write(Path(directory)/'Caddyfile', config)


def timer(service, script):
    if not re.fullmatch(r'remnacust-acme-[a-z0-9][a-z0-9_-]*', service):
        raise ValueError('Некорректное имя таймера')
    if not Path(script).is_absolute() or any(c in script for c in '\n\r\0'):
        raise ValueError('Некорректный путь задачи ACME')
    # systemd specifiers and ExecStart quoting are distinct from shell quoting.
    escaped = script.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    write(Path('/etc/systemd/system')/(service+'.service'),
          '[Unit]\nDescription=Renew Remnacust TLS certificate\nAfter=network-online.target docker.service\nWants=network-online.target\n\n'
          '[Service]\nType=oneshot\nUMask=0077\nExecStart="'+escaped+'"\n', mode=0o644)
    write(Path('/etc/systemd/system')/(service+'.timer'),
          '[Unit]\nDescription=Remnacust certificate renewal\n\n[Timer]\nOnCalendar=*-*-* 03,15:00:00\n'
          'RandomizedDelaySec=3600\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n', mode=0o644)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('operation', choices=['validate', 'copy', 'credentials', 'caddy', 'record', 'paths', 'timer'])
    for key in ['domain', 'certificate', 'key', 'directory', 'method', 'source', 'target', 'state', 'service', 'script']:
        p.add_argument('--'+key)
    p.add_argument('--email', default='')
    p.add_argument('--subscription-urls', default='')
    a = p.parse_args()
    if a.operation == 'validate':
        certificate_pair(a.domain, a.certificate, a.key, a.subscription_urls)
    elif a.operation == 'copy':
        copy_pair(a.domain, a.certificate, a.key, a.directory, a.subscription_urls)
    elif a.operation == 'credentials':
        credentials(a.method, a.source, a.target)
    elif a.operation == 'caddy':
        caddy(a.domain, a.email, a.method, a.directory, a.subscription_urls)
    elif a.operation == 'timer':
        timer(a.service, a.script)
    else:
        state = json.loads(Path(a.state).read_text())
        if a.operation == 'record':
            # Keep the original absolute paths, including Certbot's live symlinks.
            state['tls'] = {'method': a.method, 'certificate': str(Path(a.certificate).absolute()), 'key': str(Path(a.key).absolute())}
            write(a.state, state)
        else:
            tls = state.get('tls', {})
            if not tls.get('certificate') or not tls.get('key'):
                raise ValueError('Нет сохранённых путей TLS')
            print(tls['certificate']); print(tls['key'])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError, configparser.Error, subprocess.SubprocessError) as error:
        # Rejected file contents and provider credentials must not enter the log.
        print('Ошибка TLS: '+(str(error) if isinstance(error, ValueError) else 'проверьте PEM, INI, пути и OpenSSL'), file=sys.stderr)
        raise SystemExit(1)
