import argparse
import base64
import gzip
import importlib.util
import io
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'REMNACUST_INSTALLER_PAYLOAD_V1'


def render_entry(payload):
    if ('\n' + MARKER + '\n').encode() in b'\n' + payload + b'\n':
        raise ValueError('Installer payload delimiter collision')
    header = '''#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ ${1:-} != @ ]] || shift
[[ ${1:-} != install ]] || shift
directory=$(mktemp -d /tmp/remnacust-install.XXXXXXXX)
trap '[[ $directory == /tmp/remnacust-install.* ]] && rm -rf -- "$directory"' EXIT
cat > "$directory/installer.sh" <<'REMNACUST_INSTALLER_PAYLOAD_V1'
'''
    tail = '''REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
'''
    return header.encode() + payload.rstrip(b'\n') + b'\n' + tail.encode()


def build(root):
    spec = importlib.util.spec_from_file_location('entry_helper_bundle', root / 'installer/helper_bundle.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    entry, raw, files = helper.source_bundle(root)
    bundled = helper.render(entry, raw, files)
    encoded = b''.join(line[7:] for line in bundled.split(helper.FOOTER, 1)[1].splitlines() if line.startswith(b'# DATA '))
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode='wb', filename='', compresslevel=9, mtime=0) as stream:
        stream.write(gzip.decompress(base64.b64decode(encoded, validate=True)))
    encoded = base64.b64encode(buffer.getvalue())
    footer = helper.FOOTER + b''.join(b'# DATA ' + encoded[index:index + 100] + b'\n' for index in range(0, len(encoded), 100)) + helper.END
    return render_entry(helper.code(entry) + footer)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = build(ROOT)
    target = ROOT / 'Install.sh'
    if args.check:
        if not target.is_file() or target.read_bytes() != expected:
            raise SystemExit('Regenerate Install.sh: python3 scripts/build-install-entry.py')
    else:
        target.write_bytes(expected)
    print('Install.sh: verified bundled installer')


if __name__ == '__main__':
    main()
