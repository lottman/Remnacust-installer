#!/usr/bin/env python3
"""Read Marzban's API and create users through the panel's public API."""
import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from runtime import write, load


class MigrationError(Exception):
    pass


def credential(name, prompt, hidden=True):
    value = os.environ.get(name)
    if value:
        return value
    if not sys.stdin.isatty():
        raise MigrationError('Missing environment variable for noninteractive migration: ' + name)
    return getpass.getpass(prompt) if hidden else input(prompt)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise MigrationError('HTTP redirect rejected; use the final panel URL')


class Api:
    def __init__(self, url, token=''):
        u = urllib.parse.urlsplit(url)
        if u.scheme not in {'https', 'http'} or not u.hostname or u.username or u.password or u.query or u.fragment:
            raise MigrationError('Use a panel URL without credentials, query or fragment')
        if u.scheme == 'http' and u.hostname not in {'127.0.0.1', 'localhost', '::1'}:
            raise MigrationError('Remote panels require HTTPS; use a local SSH tunnel for HTTP')
        self.url, self.token = url.rstrip('/'), token
        self.headers = {'X-Forwarded-Proto': 'https', 'X-Forwarded-For': '127.0.0.1'} if u.hostname in {'127.0.0.1', 'localhost', '::1'} else {}
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, method, path, body=None, form=False, missing=False):
        headers = {'Accept': 'application/json', **self.headers}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        data = None
        if body is not None:
            data = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
        for attempt in range(3 if method == 'GET' else 1):
            try:
                req = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
                with self.opener.open(req, timeout=45) as response:
                    content = response.read(32 * 1024 * 1024 + 1)
                    if len(content) > 32 * 1024 * 1024:
                        raise MigrationError('API response too large')
                    return json.loads(content)
            except urllib.error.HTTPError as error:
                if missing and error.code == 404:
                    return None
                if method == 'GET' and error.code in {429, 502, 503, 504} and attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                raise MigrationError('API request failed: HTTP ' + str(error.code)) from None
            except (urllib.error.URLError, TimeoutError):
                if method == 'GET' and attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                raise MigrationError('API connection failed; no automatic POST retry') from None


def timestamp(value):
    if isinstance(value, (int, float)):
        result = dt.datetime.fromtimestamp(value, dt.timezone.utc)
    else:
        result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if result.tzinfo is None:
            result = result.replace(tzinfo=dt.timezone.utc)
    return result.astimezone(dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def convert(user, squad, quota_mode='remaining', preserve_hash=False):
    name = user.get('username', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{3,36}', name):
        raise MigrationError('Username does not fit the destination format; no automatic renaming')
    status_map = {'active': 'ACTIVE', 'disabled': 'DISABLED', 'limited': 'LIMITED', 'expired': 'EXPIRED', 'on_hold': 'DISABLED'}
    if user.get('status') not in status_map:
        raise MigrationError('Unknown Marzban status')
    limit, used = int(user.get('data_limit') or 0), int(user.get('used_traffic') or 0)
    if not 0 <= limit <= 9007199254740991 or not 0 <= used <= 9007199254740991:
        raise MigrationError('Invalid traffic counters')
    strategy = (user.get('data_limit_reset_strategy') or 'no_reset').upper()
    if strategy not in {'NO_RESET', 'DAY', 'WEEK', 'MONTH', 'YEAR'}:
        raise MigrationError('Unsupported reset strategy')
    warnings = []
    if strategy == 'YEAR':
        strategy = 'NO_RESET'; warnings.append('YEAR becomes NO_RESET')
    status = status_map[user['status']]
    if user['status'] == 'on_hold':
        warnings.append('ON_HOLD stays DISABLED; activation and duration require review')
    if quota_mode == 'remaining' and limit:
        # Zero means unlimited in the destination. Exhausted accounts must remain LIMITED.
        if used >= limit:
            limit = 1
            if status in {'ACTIVE', 'LIMITED'}:
                status = 'LIMITED'
        else:
            limit -= used
        if strategy != 'NO_RESET':
            warnings.append('Remaining quota uses NO_RESET; configure future renewals after migration')
        strategy = 'NO_RESET'
    elif used:
        warnings.append('Usage starts at zero; total quota may grant the already spent traffic again')
    result = {'username': name, 'status': status, 'expireAt': timestamp(user['expire']) if user.get('expire') else '2099-12-31T23:59:59Z',
              'trafficLimitBytes': limit, 'trafficLimitStrategy': strategy, 'activeInternalSquads': [str(uuid.UUID(squad))],
              'description': user.get('note') or ''}
    if user.get('created_at'):
        result['createdAt'] = timestamp(user['created_at'])
    proxies = user.get('proxies') or {}
    unsupported = set(proxies) - {'vless', 'trojan', 'shadowsocks'}
    if unsupported:
        raise MigrationError('Unsupported protocol: configure replacement before import')
    for protocol, source, target in [('vless', 'id', 'vlessUuid'), ('trojan', 'password', 'trojanPassword'), ('shadowsocks', 'password', 'ssPassword')]:
        if protocol not in proxies:
            continue
        value = proxies[protocol].get(source)
        if not value:
            raise MigrationError('Missing protocol credential')
        if target == 'vlessUuid':
            value = str(uuid.UUID(value))
        elif not 8 <= len(value) <= 32:
            raise MigrationError('Protocol password does not fit destination validation; no regeneration')
        result[target] = value
    if not proxies:
        raise MigrationError('No supported protocol credentials')
    if preserve_hash:
        sub = urllib.parse.urlsplit(user.get('subscription_url') or '').path.rstrip('/').split('/')[-1]
        if not re.fullmatch(r'[A-Za-z0-9_-]{16,64}', sub):
            raise MigrationError('Subscription token is not a short UUID; use legacy subscription-page support')
        result['shortUuid'] = sub
    return result, warnings


def matches(user, intended):
    # Credential equality is required even when resuming after an uncertain POST result.
    fields = ['username', 'vlessUuid', 'trojanPassword', 'ssPassword', 'shortUuid', 'status', 'trafficLimitBytes', 'trafficLimitStrategy']
    for key in fields:
        if key in intended and user.get(key) != intended[key]:
            return False
    if timestamp(user['expireAt']) != timestamp(intended['expireAt']):
        return False
    assigned = {s['uuid'] if isinstance(s, dict) else s for s in user.get('activeInternalSquads', [])}
    return set(intended['activeInternalSquads']) <= assigned


def destination_user(api, name):
    value = api.request('GET', '/api/users/by-username/' + urllib.parse.quote(name, safe=''), missing=True)
    return value['response'] if value is not None else None


def export_source(api, directory, batch):
    users, total, seen = [], None, set()
    for offset in range(0, 1000000, batch):
        page = api.request('GET', '/api/users?offset=' + str(offset) + '&limit=' + str(batch))
        if total is None:
            total = page['total']
        if page['total'] != total or not isinstance(page.get('users'), list):
            raise MigrationError('Source users changed during export; retry during a quiet period')
        for user in page['users']:
            if user.get('username') in seen:
                raise MigrationError('Duplicate source user or unstable pagination')
            seen.add(user.get('username')); users.append(user)
        if len(users) == total:
            break
        if not page['users'] or len(users) > total:
            raise MigrationError('Incomplete source export')
    if len(users) != total:
        raise MigrationError('Export limit exceeded')
    write(directory / 'marzban-export.json', {'users': users, 'total': total})
    return users


def run(args):
    if Path(args.output).is_symlink():
        raise MigrationError('Report directory must not be a symbolic link')
    directory = Path(args.output).resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink() or any(directory.iterdir()):
        raise MigrationError('Use a new empty report directory')
    os.chmod(directory, 0o700)
    source = Api(args.source_url)
    destination = Api(args.destination_url, credential('REMNACUST_API_TOKEN', 'Remnacust API token: '))
    username = credential('MARZBAN_USERNAME', 'Marzban admin: ', hidden=False)
    password = credential('MARZBAN_PASSWORD', 'Marzban password: ')
    source.token = source.request('POST', '/api/admin/token', {'username': username, 'password': password}, form=True)['access_token']
    squads = destination.request('GET', '/api/internal-squads')['response']['internalSquads']
    if not any(s['uuid'] == args.internal_squad for s in squads):
        raise MigrationError('Internal squad does not exist in destination')
    users = export_source(source, directory, args.batch_size)
    plan, errors = [], []
    for user in users:
        try:
            payload, warnings = convert(user, args.internal_squad, args.quota_mode, args.preserve_subhash)
            existing = destination_user(destination, payload['username'])
            if existing is not None and not matches(existing, payload):
                raise MigrationError('Destination user exists with different fields; not overwritten')
            plan.append({'payload': payload, 'warnings': warnings, 'existing': existing is not None})
        except (MigrationError, ValueError, KeyError, TypeError) as error:
            errors.append({'username': user.get('username'), 'reason': str(error) if isinstance(error, MigrationError) else 'Invalid source fields'})
    write(directory / 'plan.json', {'users': plan, 'errors': errors, 'quotaMode': args.quota_mode})
    print(f'Export: {len(users)}; ready: {sum(not u["existing"] for u in plan)}; already identical: {sum(u["existing"] for u in plan)}; conflicts: {len(errors)}')
    print('Protected export and plan: ' + str(directory))
    if errors:
        raise MigrationError('Preflight failed; destination unchanged. Review plan.json')
    if args.dry_run:
        print('Dry run completed; no users written')
        return
    if not args.yes and input('Create users from this plan? Type yes: ') != 'yes':
        print('Cancelled; destination unchanged'); return
    report = {'created': [], 'identical': [], 'failed': []}
    for item in plan:
        payload = item['payload']; name = payload['username']
        try:
            current = destination_user(destination, name)
            if current is None:
                try:
                    destination.request('POST', '/api/users', payload)
                except MigrationError:
                    # A response may be lost after a committed creation: reconcile, never blindly retry.
                    pass
                current = destination_user(destination, name)
                if current is None or not matches(current, payload):
                    raise MigrationError('Creation not verified; rerun preflight to reconcile')
                report['created'].append(name)
            elif matches(current, payload):
                report['identical'].append(name)
            else:
                raise MigrationError('Destination changed since preflight; no overwrite')
        except MigrationError as error:
            report['failed'].append({'username': name, 'reason': str(error)})
        write(directory / 'result.json', report)
    write(directory / 'SHA256SUMS', ''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in sorted(directory.glob('*.json'))))
    print(f'Created: {len(report["created"])}; identical: {len(report["identical"])}; failed: {len(report["failed"])}')
    if report['failed']:
        raise MigrationError('Partial import; result.json lists failures. Existing users were not modified')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-url', required=True); p.add_argument('--destination-url', required=True)
    p.add_argument('--internal-squad', required=True); p.add_argument('--output', required=True)
    p.add_argument('--batch-size', type=int, default=100); p.add_argument('--quota-mode', choices=['remaining', 'total'], default='remaining')
    p.add_argument('--dry-run', action='store_true'); p.add_argument('--yes', action='store_true')
    p.add_argument('--preserve-subhash', action='store_true')
    args = p.parse_args()
    if not 1 <= args.batch_size <= 500:
        p.error('batch-size: 1–500')
    uuid.UUID(args.internal_squad)
    run(args)


if __name__ == '__main__':
    try:
        main()
    except (MigrationError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as error:
        print(str(error) if isinstance(error, MigrationError) else 'Migration failed: check input and API format. Credentials were not printed.', file=sys.stderr)
        raise SystemExit(1)
