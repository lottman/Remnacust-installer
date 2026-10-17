import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('cleanup', Path(__file__).parents[1] / 'image_cleanup.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def image(n, tags=None, digests=None, source=None):
    return {'Id': 'sha256:' + f'{n:064x}', 'RepoTags': tags or [], 'RepoDigests': digests or [],
            'Config': {'Labels': {'org.opencontainers.image.source': source} if source else {}}}


class CleanupTests(unittest.TestCase):
    def test_component_only_unused_references_are_selected(self):
        images = [image(1, ['ghcr.io/lottman/remnacust-panel:current']),
                  image(2, ['remnacust-panel:previous']),
                  image(3, ['ghcr.io/lottman/remnacust-panel:old'], ['ghcr.io/lottman/remnacust-panel@sha256:' + 'a' * 64]),
                  image(4, ['postgres:18.4']), image(5, ['caddy:2.9']), image(6, ['remnacust-node:old']),
                  image(7, ['ghcr.io/lottman/remnacust-subscription-page:old', 'foreign/app:keep']),
                  image(8, source='https://github.com/lottman/Remnacust-panel'), image(9)]
        result = m.removal_plan(images, {images[0]['Id'], images[1]['Id']}, 'panel')
        self.assertEqual([item[0] for item in result], [images[2]['Id'], images[6]['Id'], images[7]['Id']])
        self.assertNotIn('foreign/app:keep', result[1][1])
        self.assertEqual(m.removal_plan(images, {images[5]['Id']}, 'node'), [])

    def test_stopped_and_concurrently_created_containers_are_protected(self):
        old = image(1, ['remnacust-node:old'])

        def docker(*args, **kwargs):
            if args[:2] == ('image', 'ls'):
                return old['Id'] + '\n'
            if args[:2] == ('image', 'inspect'):
                return [old]
            if args[:2] == ('image', 'rm'):
                self.fail('Protected image must never be removed')

        with patch.object(m, 'used_images', side_effect=[set(), {old['Id']}]), patch.object(m, 'docker', side_effect=docker):
            m.cleanup('node', '', [])

    def test_no_force_global_prune_or_foreign_references(self):
        old = image(1, ['remnacust-panel:old'])
        calls = []

        def docker(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('image', 'ls'):
                return old['Id'] + '\n'
            if args[:2] == ('image', 'inspect'):
                return [old]
            return ''

        with patch.object(m, 'used_images', return_value=set()), patch.object(m, 'docker', side_effect=docker):
            m.cleanup('panel', '', [])
        self.assertIn(('image', 'rm', 'remnacust-panel:old'), calls)
        self.assertFalse(any('prune' in call or '--force' in call or '-f' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
