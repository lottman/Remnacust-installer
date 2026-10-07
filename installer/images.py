"""Validate release images before importing them into Docker."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def validate(root, tag, assets):
    root = Path(root)
    manifest = json.loads((root/'images.json').read_text())
    lock = json.loads((root/'component-sources.json').read_text())
    if manifest.get('schema') != 1 or manifest.get('release') != tag:
        raise ValueError('Неверный выпуск Docker-образов')
    components = manifest.get('components', {})
    if set(components) != {'panel', 'node', 'subscription-page'}:
        raise ValueError('Неполный список Docker-образов')
    indexed = {a['name']: a for a in assets.get('assets', []) if a.get('state') == 'uploaded'}
    for component, entry in components.items():
        pin = lock['node' if component == 'node' else 'panel']
        if entry.get('version') != pin['version'] or entry.get('commit') != pin['commit']:
            raise ValueError('Образ не соответствует исходникам: ' + component)
        if set(entry.get('architectures', {})) != {'amd64', 'arm64'}:
            raise ValueError('Не опубликованы обе архитектуры: ' + component)
        for arch, image in entry['architectures'].items():
            name = f'remnacust-{component}-{tag}-linux-{arch}.tar.gz'
            expected = f'ghcr.io/lottman/remnacust-{component}:{entry["version"]}-{tag}-{arch}'
            if image.get('file') != name or image.get('image') != expected:
                raise ValueError('Неверное имя Docker-образа')
            if not re.fullmatch(re.escape(f'ghcr.io/lottman/remnacust-{component}@sha256:') + r'[a-f0-9]{64}', image.get('registry', '')):
                raise ValueError('Неверный адрес реестра Docker-образов')
            if not re.fullmatch(r'[a-f0-9]{64}', image.get('sha256', '')) or not re.fullmatch(r'sha256:[a-f0-9]{64}', image.get('imageId', '')):
                raise ValueError('Неверная контрольная сумма Docker-образа')
            asset = indexed.get(name, {})
            prefix = f'https://github.com/{assets["repository"]}/releases/download/{tag}/'
            if asset.get('browser_download_url') != prefix + name or asset.get('digest') != 'sha256:' + image['sha256']:
                raise ValueError('Образ не подтверждён метаданными GitHub: ' + name)
            if not isinstance(asset.get('size'), int) or not 0 < asset['size'] <= 2 * 1024**3:
                raise ValueError('Неверный размер Docker-образа')
    return manifest


def select(root, tag, assets, component, arch):
    manifest = validate(root, tag, assets)
    if arch not in {'amd64', 'arm64'}:
        raise ValueError('Поддерживаются только amd64 и arm64')
    entry = manifest['components'][component]
    image = entry['architectures'][arch]
    asset = next(a for a in assets['assets'] if a['name'] == image['file'])
    return {**image, 'version': entry['version'], 'commit': entry['commit'],
            'architecture': arch, 'url': asset['browser_download_url'], 'size': asset['size']}


def check_config(config, image):
    labels = config.get('config', {}).get('Labels') or {}
    if config.get('architecture') != image['architecture'] or config.get('os') != 'linux':
        raise ValueError('Архитектура образа не подходит серверу')
    if labels.get('org.opencontainers.image.version') != image['version'] or labels.get('org.opencontainers.image.revision') != image['commit']:
        raise ValueError('Версия или исходники внутри образа отличаются от выпуска')


def verify_archive(path, image):
    if digest_file(path) != image['sha256']:
        raise ValueError('SHA-256 Docker-образа не совпадает')
    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) > 10000 or sum(m.size for m in members) > 8 * 1024**3:
            raise ValueError('Архив Docker-образа слишком большой')
        names = set()
        for member in members:
            name = PurePosixPath(member.name)
            if name.is_absolute() or '..' in name.parts or '\\' in member.name or not (member.isdir() or member.isfile()):
                raise ValueError('Небезопасный путь в Docker-образе')
            if name in names:
                raise ValueError('Повторяющийся путь в Docker-образе')
            names.add(name)
        listing = archive.extractfile('manifest.json')
        if not listing or archive.getmember('manifest.json').size > 1024 * 1024:
            raise ValueError('Нет manifest.json Docker-образа')
        manifests = json.load(listing)
        if len(manifests) != 1 or manifests[0].get('RepoTags') != [image['image']]:
            raise ValueError('Архив содержит другой образ или несколько образов')
        config_file = archive.extractfile(manifests[0]['Config'])
        if not config_file or archive.getmember(manifests[0]['Config']).size > 1024 * 1024:
            raise ValueError('Нет конфигурации Docker-образа')
        content = config_file.read()
        if 'sha256:' + hashlib.sha256(content).hexdigest() != image['imageId']:
            raise ValueError('Идентификатор Docker-образа не совпадает')
        check_config(json.loads(content), image)


def verify_inspect(inspected, image):
    # Classic Docker reports the config digest; containerd reports the manifest digest.
    allowed = {image['imageId'], image['registry'].rsplit('@', 1)[1]}
    if len(inspected) != 1 or inspected[0]['Id'] not in allowed:
        raise ValueError('Docker загрузил другой образ')
    item = inspected[0]
    check_config({'architecture': item['Architecture'], 'os': item['Os'], 'config': item['Config']}, image)


def verify_saved(stream, image):
    """Check the actual named image after an import that regenerated its manifest."""
    listing = None
    configs = {}
    names = set()
    size = 0
    with tarfile.open(fileobj=stream, mode='r|') as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or '..' in name.parts or '\\' in member.name or not (member.isdir() or member.isfile()):
                raise ValueError('Небезопасный путь в Docker-образе')
            size += member.size
            if name in names or len(names) >= 10000 or size > 8 * 1024**3:
                raise ValueError('Неверный архив загруженного Docker-образа')
            names.add(name)
            if not member.isfile() or member.size > 1024 * 1024:
                continue
            if member.name == 'manifest.json':
                listing = json.load(archive.extractfile(member))
            elif member.name.endswith('.json') or name.parts[:2] == ('blobs', 'sha256'):
                content = archive.extractfile(member).read()
                if 'sha256:' + hashlib.sha256(content).hexdigest() == image['imageId']:
                    configs[member.name] = content
    if not listing or len(listing) != 1 or listing[0].get('RepoTags') != [image['image']]:
        raise ValueError('Архив содержит другой образ или несколько образов')
    content = configs.get(listing[0].get('Config'))
    if content is None:
        raise ValueError('Идентификатор загруженного Docker-образа не совпадает')
    check_config(json.loads(content), image)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['validate', 'select', 'archive', 'inspect', 'saved'])
    parser.add_argument('--root', type=Path)
    parser.add_argument('--tag')
    parser.add_argument('--assets', type=Path)
    parser.add_argument('--repository')
    parser.add_argument('--component', choices=['panel', 'node', 'subscription-page'])
    parser.add_argument('--architecture')
    parser.add_argument('--image', type=Path)
    parser.add_argument('--file', type=Path)
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args()
    if args.action in {'validate', 'select'}:
        assets = json.loads(args.assets.read_text())
        assets['repository'] = args.repository
        if args.action == 'validate':
            validate(args.root, args.tag, assets)
        else:
            print(json.dumps(select(args.root, args.tag, assets, args.component, args.architecture)))
    else:
        image = json.loads(args.image.read_text())
        try:
            if args.action == 'archive':
                verify_archive(args.file, image)
            elif args.action == 'saved':
                verify_saved(sys.stdin.buffer, image)
            else:
                verify_inspect(json.loads(args.file.read_text()), image)
        except (ValueError, KeyError, tarfile.TarError) as error:
            if not args.quiet:
                print(str(error), file=sys.stderr)
            raise SystemExit(1)
