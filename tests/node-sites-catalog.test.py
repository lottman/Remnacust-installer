import ast
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_node_sites', ROOT / 'scripts/build-node-sites.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class NodeSitesCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = builder.build_catalog()
        cls.catalog = json.loads(cls.data)

    def test_contract_determinism_and_generated_catalog(self):
        self.assertEqual(set(self.catalog), {'schema','sites'})
        self.assertEqual(self.catalog['schema'], 1)
        self.assertTrue(builder.CSP.endswith("form-action 'none';"))
        self.assertEqual(len(self.catalog['sites']), 20)
        self.assertLessEqual(len(self.data), 2 * 1024 * 1024)
        self.assertEqual(self.data, builder.build_catalog())
        self.assertEqual(self.data, (ROOT / 'installer/node-sites.json').read_bytes())
        self.assertEqual([s['id'] for s in self.catalog['sites']], sorted(builder.EXPECTED_IDS))
        for site in self.catalog['sites']:
            self.assertEqual(set(site), {'id','title','description','files'})
            self.assertTrue(any('\u0400' <= c <= '\u04ff' for c in site['title']))

    def test_pages_links_assets_and_distinct_compositions(self):
        styles, structures = set(), set()
        for site in self.catalog['sites']:
            files = site['files']
            with self.subTest(site=site['id']):
                self.assertGreaterEqual(sum(f.endswith('.html') for f in files), 5)
                self.assertTrue({'index.html','about.html','404.html'}.issubset(files))
                self.assertIn('assets/site.js', files)
                self.assertIn('assets/scene.svg', files)
                self.assertIn('assets/base.css', files)
                self.assertNotIn('site.json', files)
                builder.validate_site(files)
                styles.add(files['assets/site.css'])
                main = files['index.html'].split('<main id="main">')[1].split('</main>')[0]
                structures.add(tuple(builder.re.findall(r'<(?:section|aside|div)[^>]*class="([^"]+)"', main)))
                self.assertIn('prefers-reduced-motion', files['assets/base.css'])
                self.assertIn(':focus-visible', files['assets/base.css'])
                self.assertIn('max-width:430px', files['assets/base.css'])
                for name, content in files.items():
                    if name.endswith('.html'):
                        self.assertEqual(content.count('{{DOMAIN}}'), 1)
                        self.assertIn(builder.CSP, content)
                    else:
                        self.assertNotIn('{{DOMAIN}}', content)
        self.assertEqual(len(styles), 20)
        self.assertEqual(len(structures), 20)

    def test_data_only_helper_roundtrip_determinism_and_bounds(self):
        helper = builder.build_catalog_helper(self.data)
        self.assertEqual(helper, builder.build_catalog_helper(builder.build_catalog()))
        self.assertEqual(helper, (ROOT / 'installer/node_site_catalog.py').read_bytes())
        self.assertLessEqual(len(helper), builder.MAX_BYTES)
        source = helper.decode('utf-8')
        self.assertTrue(source.startswith('CATALOG_JSON = '))
        self.assertTrue(source.endswith('\n'))
        self.assertEqual(len(source.splitlines()), 1)
        self.assertEqual(ast.literal_eval(source[len(builder.HELPER_PREFIX):]), self.data.decode('utf-8'))
        syntax = ast.parse(source)
        self.assertEqual(len(syntax.body), 1)
        assignment = syntax.body[0]
        self.assertIsInstance(assignment, ast.Assign)
        self.assertEqual(len(assignment.targets), 1)
        self.assertIsInstance(assignment.targets[0], ast.Name)
        self.assertEqual(assignment.targets[0].id, 'CATALOG_JSON')
        self.assertIsInstance(assignment.value, ast.Constant)
        self.assertIsInstance(assignment.value.value, str)
        sample = json.dumps({'text': 'Кавычки: \' " \\ \n</script>\u2028'}, ensure_ascii=False).encode('utf-8')
        self.assertEqual(ast.literal_eval(builder.build_catalog_helper(sample).decode('utf-8')[len(builder.HELPER_PREFIX):]), sample.decode('utf-8'))
        for data in [b'x' * (builder.MAX_BYTES + 1), b'\\' * (builder.MAX_BYTES // 2 + 1)]:
            with self.assertRaises(ValueError):
                builder.build_catalog_helper(data)

    def test_cli_checks_both_artifacts_and_detects_stale_helper(self):
        with tempfile.TemporaryDirectory(prefix='remnacust-catalog-build-') as directory:
            output = Path(directory) / 'node-sites.json'
            helper = output.with_name('node_site_catalog.py')
            command = [sys.executable, str(ROOT / 'scripts/build-node-sites.py'), '--output', str(output)]
            def run(*extra):
                return subprocess.run([*command,*extra],capture_output=True,text=True,timeout=20)
            self.assertEqual(run().returncode, 0)
            self.assertEqual(output.read_bytes(), self.data)
            self.assertEqual(helper.read_bytes(), builder.build_catalog_helper(self.data))
            self.assertEqual(run('--check').returncode, 0)
            helper.write_bytes(b'CATALOG_JSON = "stale"\n')
            stale = run('--check')
            self.assertEqual(stale.returncode, 1)
            self.assertIn('node_site_catalog.py is missing or stale', stale.stderr)
            self.assertEqual(output.read_bytes(), self.data)
            helper.unlink()
            self.assertEqual(run('--check').returncode, 1)
            self.assertEqual(run().returncode, 0)
            self.assertEqual(helper.read_bytes(), builder.build_catalog_helper(self.data))

    def test_script_syntax(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js unavailable for optional syntax checks')
        for site in self.catalog['sites']:
            with self.subTest(site=site['id']):
                result = subprocess.run([node, '--check', str(ROOT / 'sites' / site['id'] / 'assets/site.js')],capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_required_pages_cannot_be_omitted(self):
        for name in ['index.html','about.html','404.html']:
            files = copy.deepcopy(self.catalog['sites'][0]['files'])
            del files[name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                builder.validate_site(files)

    def test_external_traversal_and_missing_resources_are_rejected(self):
        files = self.catalog['sites'][0]['files']
        for reference in ['https://example.test/x','//example.test/x','javascript:alert(1)','data:text/html,x','../secrets','%2e%2e/secrets','assets/no.css','/outside.html','assets\\site.js']:
            with self.subTest(reference=reference), self.assertRaises(ValueError):
                builder.local_path(reference, 'index.html', files)

    def test_inline_code_unsafe_sinks_and_csp_changes_are_rejected(self):
        source = self.catalog['sites'][0]['files']
        for injected in ['<script>alert(1)</script>','<style>body{color:red}</style>','<button onclick="alert(1)">Open</button>','<div style="color:red">Text</div>','<iframe src="index.html"></iframe>']:
            files = copy.deepcopy(source)
            files['index.html'] = files['index.html'].replace('</main>',injected+'</main>')
            with self.subTest(injected=injected), self.assertRaises(ValueError):
                builder.validate_site(files)
        for code in ['fetch("/track")','node.innerHTML = input','document.write(input)','new Function(input)']:
            files = copy.deepcopy(source)
            files['assets/site.js'] += '\n'+code
            with self.subTest(code=code), self.assertRaises(ValueError):
                builder.validate_site(files)
        files = copy.deepcopy(source)
        files['index.html'] = files['index.html'].replace(builder.CSP,"default-src *")
        with self.assertRaises(ValueError):
            builder.validate_site(files)

    def test_placeholders_and_active_svg_are_rejected(self):
        source = self.catalog['sites'][0]['files']
        for name, text in [('assets/site.js',"const name='{{DOMAIN}}';"),('index.html','<a href="{{DOMAIN}}">Domain</a>'),('index.html','{{TOKEN}}'),('assets/scene.svg','<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')]:
            files = copy.deepcopy(source)
            files[name] = text if name.endswith('.svg') else files[name]+text
            with self.subTest(name=name,text=text), self.assertRaises(ValueError):
                builder.validate_site(files)

    def test_symlinked_asset_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='remnacust-sites-source-') as directory:
            source = Path(directory) / 'sites'
            shutil.copytree(ROOT / 'sites', source)
            target = source / 'shoes/assets/site.js'
            target.unlink()
            try:
                target.symlink_to(source / 'coffee/assets/site.js')
            except OSError:
                self.skipTest('Host does not permit symlinks')
            with self.assertRaises(ValueError):
                builder.build_catalog(source)


if __name__ == '__main__':
    unittest.main()
