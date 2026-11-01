"""Run the candidate panel's read-only continuity CLI beside an older panel."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

WRAPPER = r'''
try {
 const fs = require('node:fs'), file = '/opt/app/dist/cli.js';
 if (!fs.readFileSync(file, 'utf8').includes('check-node-continuity')) process.exit(1);
 const result = require('node:child_process').spawnSync(process.execPath, [file, 'check-node-continuity'],
   {timeout:120000,maxBuffer:16384,killSignal:'SIGKILL',stdio:['ignore','pipe','ignore']});
 if (result.error || result.signal || result.status !== 0) process.exit(1);
 const value = JSON.parse(result.stdout.toString('utf8'));
 if (value?.ready !== true || !Number.isSafeInteger(value.nodeCount) || value.nodeCount < 0 || value.nodeCount > 10000) process.exit(1);
 process.stdout.write(String(value.nodeCount));
} catch { process.exit(1); }
'''


def run_probe(inspect_file, image):
    if not image or image.startswith('-') or len(image) > 512 or not re.fullmatch(r'[A-Za-z0-9_./:@-]+', image):
        raise ValueError('Invalid candidate image')
    source = Path(inspect_file)
    if source.stat().st_size > 4 * 1024 * 1024:
        raise ValueError('Inspect exceeds limit')
    records = json.loads(source.read_text())
    if not isinstance(records, list) or len(records) != 1:
        raise ValueError('Invalid current container')
    current = records[0]
    container = current.get('Id', '')
    environment = current.get('Config', {}).get('Env', [])
    if not re.fullmatch(r'[a-f0-9]{64}', container) or not isinstance(environment, list) or len(environment) > 1000:
        raise ValueError('Invalid current container')
    lines = []
    for value in environment:
        if not isinstance(value, str) or '\n' in value or '\r' in value or '\x00' in value or '=' not in value:
            raise ValueError('Unsupported environment')
        key, _ = value.split('=', 1)
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
            raise ValueError('Invalid environment key')
        lines.append(value)
    if sum(len(line.encode()) for line in lines) > 256 * 1024:
        raise ValueError('Environment exceeds limit')
    # No host mounts, Docker socket, entrypoint, public listener or writable root.
    # The existing panel remains running; only its network namespace is shared.
    candidate = None
    with tempfile.TemporaryDirectory(prefix='remnacust-continuity-') as directory:
        env_file = Path(directory) / 'environment'
        descriptor = os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write('\n'.join(lines) + '\n')
        try:
            created = subprocess.run([
                'docker', 'create', '--label', 'remnacust.continuity=' + uuid.uuid4().hex,
                '--network', 'container:' + container, '--read-only', '--cap-drop=ALL',
                '--security-opt=no-new-privileges', '--env-file', str(env_file),
                '--workdir', '/opt/app', '--entrypoint', 'node', image, '-e', WRAPPER,
            ], capture_output=True, text=True, timeout=30, check=True)
            candidate = created.stdout.strip()
            if not re.fullmatch(r'[a-f0-9]{64}', candidate):
                candidate = None
                raise ValueError('Invalid probe identity')
            result = subprocess.run(['docker', 'start', '--attach', candidate],
                                    capture_output=True, text=True, timeout=130, check=True)
            count = result.stdout.strip()
            if not re.fullmatch(r'\d{1,5}', count) or int(count) > 10000:
                raise ValueError('Invalid continuity result')
            return int(count)
        finally:
            if candidate:
                subprocess.run(['docker', 'rm', '--force', candidate], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=15, check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inspect', required=True)
    parser.add_argument('--image', required=True)
    args = parser.parse_args()
    try:
        print(run_probe(args.inspect, args.image))
    except Exception:
        # Docker/DB errors may contain credentials. Only a fixed diagnostic escapes.
        raise SystemExit('Node continuity could not be confirmed')


if __name__ == '__main__':
    main()
