#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${1:-} != @ ]] || shift
[[ ${1:-} != install ]] || shift
for tool in curl python3; do
    command -v "$tool" >/dev/null || { printf 'Нужен %s\n' "$tool" >&2; exit 1; }
done
work=$(mktemp -d /tmp/remnacust-bootstrap.XXXXXXXX)
trap '[[ $work == /tmp/remnacust-bootstrap.* ]] && rm -rf -- "$work"' EXIT
request=(--fail --silent --show-error --retry 3 --connect-timeout 15 --max-time 90 --proto '=https' --proto-redir '=https' --tlsv1.2)
tag=''
if curl "${request[@]}" --max-time 20 --max-filesize 1048576 --output "$work/release.json" https://api.github.com/repos/lottman/Remnacust-installer/releases/latest 2>/dev/null; then
    tag=$(python3 -I - "$work/release.json" <<'PY'
import json
from pathlib import Path
import re
import sys
data = Path(sys.argv[1]).read_bytes()
if len(data) > 1048576:
    raise SystemExit(1)
release = json.loads(data)
tag = release.get('tag_name')
if release.get('draft') is not False or release.get('prerelease') is not False or not isinstance(tag, str) or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
    raise SystemExit(1)
print(tag)
PY
    ) || tag=''
fi
if [[ -z $tag ]]; then
curl "${request[@]}" --head --http1.1 --max-time 30 --max-filesize 16384 --dump-header "$work/headers" --output /dev/null https://github.com/lottman/Remnacust-installer/releases/latest
tag=$(python3 -I - "$work/headers" <<'PY'
from pathlib import Path
import re
import sys
raw = Path(sys.argv[1]).read_bytes()
if len(raw) > 16384:
    raise SystemExit('Некорректный ответ GitHub')
locations = re.findall(rb'(?im)^location:[ \t]*([^\r\n]+)', raw)
if len(locations) != 1:
    raise SystemExit('Не удалось определить последний выпуск')
match = re.fullmatch(rb'https://github\.com/lottman/Remnacust-installer/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)', locations[0])
if not match:
    raise SystemExit('Некорректный адрес выпуска')
print(match[1].decode('ascii'))
PY
)
fi
printf 'Загрузка установщика %s\n' "$tag"
curl "${request[@]}" --location --max-filesize 8388608 --output "$work/source.tar.gz" "https://codeload.github.com/lottman/Remnacust-installer/tar.gz/refs/tags/$tag"
python3 -I - "$work" "$tag" <<'PY'
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile

work, tag = Path(sys.argv[1]), sys.argv[2]
if (work / 'source.tar.gz').stat().st_size > 8388608:
    raise SystemExit('Архив установщика слишком большой')
with gzip.open(work / 'source.tar.gz', 'rb') as stream:
    payload = stream.read(32 * 1024 * 1024 + 1)
if len(payload) > 32 * 1024 * 1024:
    raise SystemExit('Распакованный архив слишком большой')
prefix = 'Remnacust-installer-' + tag[1:]
files, names = {}, set()
with tarfile.open(fileobj=io.BytesIO(payload), mode='r:') as archive:
    for number, member in enumerate(archive):
        if number >= 4096:
            raise SystemExit('Слишком много файлов в архиве')
        name = member.name.rstrip('/') if member.isdir() else member.name
        path = PurePosixPath(name)
        if (path.is_absolute() or str(path) != name or not path.parts or path.parts[0] != prefix or
                '..' in path.parts or '\\' in name or any(ord(c) < 32 for c in name) or
                name.casefold() in names or not (member.isfile() or member.isdir()) or
                member.size < 0 or member.size > 2 * 1024 * 1024):
            raise SystemExit('Небезопасный файл в архиве')
        names.add(name.casefold())
        if member.isfile():
            relative = '/'.join(path.parts[1:])
            if not relative:
                raise SystemExit('Некорректный корень архива')
            files[relative] = archive.extractfile(member).read()
normal = lambda data: data.replace(b'\r\n', b'\n')
entry = normal(files.get('installer/installer.sh', b''))
raw = normal(files.get('installer/helper-contract.json', b''))
anchors = re.findall(rb"(?m)^HELPER_BUNDLE_SHA256='([a-f0-9]{64})'$", entry)
if len(anchors) != 1 or hashlib.sha256(raw).hexdigest().encode() != anchors[0]:
    raise SystemExit('Не совпадает контрольная сумма установщика')
contract = json.loads(raw)
canonical = re.sub(rb"(?m)^HELPER_BUNDLE_SHA256='[a-f0-9]{64}'$", b"HELPER_BUNDLE_SHA256='" + b'0' * 64 + b"'", entry).rstrip(b'\n') + b'\n'
if (contract.get('schema') != 1 or contract.get('version') != tag[1:] or
        normal(files.get('VERSION', b'')).decode('ascii').strip() != tag[1:] or
        contract.get('entry_sha256') != hashlib.sha256(canonical).hexdigest()):
    raise SystemExit('Версия или состав установщика не совпадают')
cohort = contract.get('files')
if not isinstance(cohort, dict) or not {'helper_bundle.py', 'runtime.py'} <= cohort.keys() or len(cohort) > 32:
    raise SystemExit('Неполный комплект установщика')
for name, identity in cohort.items():
    if not re.fullmatch(r'(?:[A-Za-z0-9_-]+\.(?:py|cjs)|LICENSE|NOTICE\.md)', name):
        raise SystemExit('Недопустимое имя помощника')
    relative = name if name in {'LICENSE', 'NOTICE.md'} else 'installer/' + name
    content = normal(files.get(relative, b''))
    if (not isinstance(identity, dict) or not content or len(content) != identity.get('bytes') or
            hashlib.sha256(content).hexdigest() != identity.get('sha256')):
        raise SystemExit('Повреждённый комплект установщика')
source = work / 'source'
source.mkdir(mode=0o700)
for name, content in files.items():
    target = source / name
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with target.open('xb') as stream:
        stream.write(content)
PY
entry="$work/source/installer/installer.sh"
bash -n "$entry"
if [[ $EUID == 0 ]]; then
    bash "$entry" "$@"
else
    sudo bash "$entry" "$@"
fi
