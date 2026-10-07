import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).resolve().parents[1]/'scripts/check-panel-build-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.values = ['1.1.6', 'a'*40, 'main', '2026-10-07T16:00:00Z', '42']
        self.config = {'Labels': {'org.opencontainers.image.version': self.values[0],
            'org.opencontainers.image.revision': self.values[1],
            'org.opencontainers.image.source': 'https://github.com/lottman/Remnacust-panel'},
            'Env': ['__RW_METADATA_'+k+'='+v for k, v in zip(
                ['VERSION', 'GIT_BACKEND_COMMIT', 'GIT_FRONTEND_COMMIT', 'GIT_BRANCH', 'BUILD_TIME', 'BUILD_NUMBER'],
                [self.values[0], self.values[1], self.values[1], *self.values[2:]])]}

    def test_release_image(self):
        metadata.validate(self.config, *self.values)

    def test_correct_labels_without_runtime_metadata_are_rejected(self):
        config = copy.deepcopy(self.config)
        config['Env'] = []
        with self.assertRaisesRegex(ValueError, 'Runtime'):
            metadata.validate(config, *self.values)

    def test_each_placeholder_or_stale_runtime_value_is_rejected(self):
        for index, placeholder in enumerate(['1.0.0', 'unknown', 'unknown', 'local', '', '0']):
            with self.subTest(index=index):
                config = copy.deepcopy(self.config)
                key = config['Env'][index].split('=', 1)[0]
                config['Env'][index] = key + '=' + placeholder
                with self.assertRaisesRegex(ValueError, 'Runtime'):
                    metadata.validate(config, *self.values)

    def test_legacy_repository_is_rejected(self):
        self.config['Labels']['org.opencontainers.image.source'] = 'https://github.com/lottman/remnacust'
        with self.assertRaisesRegex(ValueError, 'repository'):
            metadata.validate(self.config, *self.values)


if __name__ == '__main__':
    unittest.main()
