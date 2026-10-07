"""Regression checks for image identity, architecture and archive boundaries."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('images', Path(__file__).resolve().parents[1]/'installer/images.py')
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.tag = 'v1.1.4'
        self.lock = {k: {'version': '1.1.1' if k != 'panel' else '1.1.2', 'commit': 'a'*40} for k in ['panel', 'node', 'core']}
        self.assets = {'repository': 'lottman/Remnacust-installer', 'assets': []}
        self.manifest = {'schema': 1, 'release': self.tag, 'components': {}}
        for component in ['panel', 'node', 'subscription-page']:
            pin = self.lock['node' if component == 'node' else 'panel']
            entry = {**pin, 'architectures': {}}
            for arch in ['amd64', 'arm64']:
                name = f'remnacust-{component}-{self.tag}-linux-{arch}.tar.gz'
                image = f'ghcr.io/lottman/remnacust-{component}:{pin["version"]}-{self.tag}-{arch}'
                data = {'file': name, 'image': image, 'sha256': 'a'*64, 'imageId': 'sha256:'+'b'*64,
                        'registry': f'ghcr.io/lottman/remnacust-{component}@sha256:'+'c'*64}
                entry['architectures'][arch] = data
                self.assets['assets'].append({'name': name, 'state': 'uploaded', 'size': 1234,
                    'digest': 'sha256:'+'a'*64, 'browser_download_url': f'https://github.com/lottman/Remnacust-installer/releases/download/{self.tag}/'+name})
            self.manifest['components'][component] = entry
        self.write()

    def tearDown(self):
        self.temp.cleanup()

    def write(self):
        (self.root/'images.json').write_text(json.dumps(self.manifest))
        (self.root/'component-sources.json').write_text(json.dumps(self.lock))

    def selected(self):
        return images.select(self.root, self.tag, self.assets, 'panel', 'amd64')

    def archive(self, image, config=None, tags=None, extra=None):
        config = config or {'architecture': 'amd64', 'os': 'linux', 'config': {'Labels': {
            'org.opencontainers.image.version': image['version'], 'org.opencontainers.image.revision': image['commit']}}}
        content = json.dumps(config).encode()
        image['imageId'] = 'sha256:' + hashlib.sha256(content).hexdigest()
        files = {'config.json': content, 'manifest.json': json.dumps([{'Config': 'config.json', 'RepoTags': tags or [image['image']]}]).encode()}
        if extra:
            files.update(extra)
        path = self.root/'image.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        image['sha256'] = images.digest_file(path)
        return path

    def test_valid_architectures_and_independent_versions(self):
        self.assertEqual(self.selected()['version'], '1.1.2')
        self.assertEqual(images.select(self.root, self.tag, self.assets, 'node', 'arm64')['version'], '1.1.1')

    def test_missing_architecture_is_rejected(self):
        del self.manifest['components']['node']['architectures']['arm64']; self.write()
        with self.assertRaisesRegex(ValueError, 'архитектуры'): self.selected()

    def test_unpublished_image_is_rejected(self):
        self.assets['assets'][0]['state'] = 'pending'
        with self.assertRaisesRegex(ValueError, 'GitHub'): self.selected()

    def test_foreign_url_is_rejected(self):
        self.assets['assets'][0]['browser_download_url'] = 'https://example.com/image.tar.gz'
        with self.assertRaisesRegex(ValueError, 'GitHub'): self.selected()

    def test_wrong_commit_is_rejected(self):
        self.manifest['components']['panel']['commit'] = 'd'*40; self.write()
        with self.assertRaisesRegex(ValueError, 'исходникам'): self.selected()

    def test_mutable_registry_reference_is_rejected(self):
        self.manifest['components']['panel']['architectures']['amd64']['registry'] = 'ghcr.io/lottman/remnacust-panel:latest'; self.write()
        with self.assertRaisesRegex(ValueError, 'реестра'): self.selected()

    def test_valid_docker_archive(self):
        image = self.selected(); images.verify_archive(self.archive(image), image)

    def test_corruption_is_rejected_before_import(self):
        image = self.selected(); path = self.archive(image); image['sha256'] = 'f'*64
        with self.assertRaisesRegex(ValueError, 'SHA-256'): images.verify_archive(path, image)

    def test_archive_cannot_overwrite_another_tag(self):
        image = self.selected(); path = self.archive(image, tags=['postgres:latest'])
        with self.assertRaisesRegex(ValueError, 'другой образ'): images.verify_archive(path, image)

    def test_safe_digest_does_not_allow_path_traversal(self):
        image = self.selected(); path = self.archive(image, extra={'../outside': b'x'})
        with self.assertRaisesRegex(ValueError, 'Небезопасный'): images.verify_archive(path, image)
        self.assertFalse((self.root.parent/'outside').exists())

    def test_config_id_must_match(self):
        image = self.selected(); path = self.archive(image); image['imageId'] = 'sha256:'+'f'*64
        with self.assertRaisesRegex(ValueError, 'Идентификатор'): images.verify_archive(path, image)

    def test_wrong_architecture_inside_archive(self):
        image = self.selected(); path = self.archive(image, config={'architecture': 'arm64', 'os': 'linux', 'config': {'Labels': {}}})
        with self.assertRaisesRegex(ValueError, 'Архитектура'): images.verify_archive(path, image)

    def test_inspect_rejects_different_image(self):
        image = self.selected()
        with self.assertRaisesRegex(ValueError, 'другой образ'): images.verify_inspect([{'Id': 'sha256:'+'f'*64}], image)


if __name__ == '__main__':
    unittest.main()
