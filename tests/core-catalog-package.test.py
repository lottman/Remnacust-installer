import importlib.util
import json
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_source', root / 'scripts/package-source-release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class CoreCatalogTest(unittest.TestCase):
    def fixture(self):
        version = '1.1.9'
        entry = {'id': 'core-' + version, 'build': version, 'sourceCommit': 'a' * 40, 'artifacts': {
            arch: {'url': f'https://github.com/lottman/Remnacust-core/releases/download/v{version}/remnacust-core-{version}-linux-{arch}', 'sha256': 'b' * 64}
            for arch in ['amd64', 'arm64']}}
        return [entry]

    def check(self, catalog):
        module.validate_core_catalog({
            'component-sources.json': json.dumps({'core': {'commit': 'a' * 40}}).encode(),
            'panel/backend/src/modules/core-management/core-releases.json': json.dumps(catalog).encode(),
        }, {'panel': '1.1.7.39', 'core': '1.1.9'})

    def test_matching_verified_release(self):
        self.check(self.fixture())

    def test_empty_stale_incomplete_and_unpinned_catalogs_are_rejected(self):
        for variant in ['empty', 'version', 'commit', 'arch', 'url', 'hash', 'duplicate']:
            catalog = self.fixture()
            if variant == 'empty': catalog = []
            elif variant == 'version': catalog[0]['build'] = '1.1.8'
            elif variant == 'commit': catalog[0]['sourceCommit'] = 'c' * 40
            elif variant == 'arch': del catalog[0]['artifacts']['arm64']
            elif variant == 'url': catalog[0]['artifacts']['amd64']['url'] = 'https://example.com/core'
            elif variant == 'hash': catalog[0]['artifacts']['amd64']['sha256'] = 'bad'
            elif variant == 'duplicate': catalog += catalog[:]
            with self.subTest(variant=variant), self.assertRaises(ValueError): self.check(catalog)

if __name__ == '__main__': unittest.main()
