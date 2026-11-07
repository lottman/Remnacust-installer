import argparse
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import re
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 2 * 1024 * 1024
HELPER_PREFIX = 'CATALOG_JSON = '
EXPECTED_IDS = frozenset('shoes minecraft ceramics coffee bakery bicycles plants architecture outdoors artgallery bookshop musicstudio furniture petcare travelguide fitness codingnotes astronomy boardgames webhosting'.split())
EXTENSIONS = {'.html', '.css', '.js', '.svg'}
CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none';"
NETWORK_JS = re.compile(r'\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts|eval)\s*\(|\bnew\s+Function\b|\b(?:innerHTML|outerHTML|insertAdjacentHTML)\b|document\s*\.\s*write\s*\(')


def local_path(reference, current, available):
    parsed = urlsplit(reference)
    if parsed.scheme or parsed.netloc or reference.startswith('\\') or '\\' in reference:
        raise ValueError(f'{current}: non-local reference {reference!r}')
    if parsed.query:
        raise ValueError(f'{current}: resource query not supported')
    raw = unquote(parsed.path)
    if not raw:
        return current
    candidate = PurePosixPath(raw.lstrip('/')) if raw.startswith('/') else PurePosixPath(current).parent / raw
    if '..' in candidate.parts or str(candidate) not in available:
        raise ValueError(f'{current}: missing or unsafe resource {reference!r}')
    return str(candidate)


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.references = []
        self.links = set()
        self.ids = set()
        self.mains = 0
        self.headings = 0
        self.inline_script = False
        self.in_script = False
        self.has_title = False
        self.csp = []

    def handle_starttag(self, tag, pairs):
        attrs = dict(pairs)
        if len(attrs) != len(pairs):
            raise ValueError('Duplicate HTML attribute')
        if any(k.lower().startswith('on') or k.lower() == 'style' for k in attrs):
            raise ValueError('Inline handler or style')
        if tag in {'iframe', 'object', 'embed', 'base', 'style'}:
            raise ValueError('Unsupported active HTML element')
        if tag == 'script':
            if not attrs.get('src'):
                raise ValueError('Inline script')
            self.in_script = True
        if tag == 'form' and ('action' in attrs or 'method' in attrs):
            raise ValueError('Forms must stay local')
        if tag == 'meta' and attrs.get('http-equiv', '').lower() == 'refresh':
            raise ValueError('Meta refresh')
        if tag == 'meta' and attrs.get('http-equiv', '').lower() == 'content-security-policy':
            self.csp.append(attrs.get('content'))
        for key in ['href', 'src', 'poster']:
            if key in attrs:
                if not attrs[key]:
                    raise ValueError('Empty resource reference')
                self.references.append(attrs[key])
                if tag == 'a' and key == 'href':
                    self.links.add(attrs[key])
        if 'srcset' in attrs:
            raise ValueError('Use explicit local image sources')
        if 'id' in attrs:
            if attrs['id'] in self.ids:
                raise ValueError('Duplicate HTML id')
            self.ids.add(attrs['id'])
        self.mains += tag == 'main'
        self.headings += tag == 'h1'
        self.has_title |= tag == 'title'
        if tag == 'img' and not attrs.get('alt'):
            raise ValueError('Image needs alternative text')

    def handle_endtag(self, tag):
        if tag == 'script':
            self.in_script = False

    def handle_data(self, data):
        if self.in_script and data.strip():
            raise ValueError('Inline script content')


def validate_site(files):
    pages = {}
    for filename, text in files.items():
        if '\x00' in text:
            raise ValueError(f'{filename}: NUL byte')
        placeholders = re.findall(r'\{\{[^{}]*\}\}', text)
        if placeholders and (not filename.endswith('.html') or any(p != '{{DOMAIN}}' for p in placeholders)):
            raise ValueError(f'{filename}: unsupported placeholder')
        if filename.endswith('.html'):
            page = Page()
            page.feed(text)
            page.close()
            if page.mains != 1 or page.headings != 1 or not page.has_title:
                raise ValueError(f'{filename}: need one main, one h1 and a title')
            if page.csp != [CSP]:
                raise ValueError(f'{filename}: expected bundled content-security-policy')
            if '{{DOMAIN}}' in text:
                for token in re.findall(r'<[^>]+>', text):
                    if '{{DOMAIN}}' in token:
                        raise ValueError('Domain placeholder belongs in HTML text only')
            pages[filename] = page
            for reference in page.references:
                local_path(reference, filename, files)
        elif filename.endswith('.css'):
            if re.search(r'@import\b|expression\s*\(', text, re.I):
                raise ValueError(f'{filename}: dynamic CSS import')
            for reference in re.findall(r'url\(\s*[\'"]?([^\)\'"\s]+)', text, re.I):
                local_path(reference, filename, files)
        elif filename.endswith('.js'):
            if NETWORK_JS.search(text) or re.search(r'https?://|\bimport\s*\(', text):
                raise ValueError(f'{filename}: network or unsafe script sink')
        elif filename.endswith('.svg'):
            if re.search(r'<!DOCTYPE|<!ENTITY', text, re.I):
                raise ValueError('SVG declaration not allowed')
            svg = ET.fromstring(text)
            if svg.tag != '{http://www.w3.org/2000/svg}svg':
                raise ValueError('Invalid SVG root')
            for node in svg.iter():
                if node.tag.rsplit('}', 1)[-1] in {'script','foreignObject','style','image','use','animate','set'}:
                    raise ValueError('Active or linked SVG element')
                for key, value in node.attrib.items():
                    short = key.rsplit('}', 1)[-1].lower()
                    if short.startswith('on') or short in {'style','href'} or re.search(r'url\(\s*[\'"]?(?!#)', value):
                        raise ValueError('Unsafe SVG attribute')
    if len(pages) < 5 or not {'index.html','about.html','404.html'}.issubset(pages):
        raise ValueError('A site needs index, about, 404 and two thematic pages')
    reachable, pending = set(), ['index.html']
    while pending:
        current = pending.pop()
        if current in reachable:
            continue
        reachable.add(current)
        for reference in pages[current].links:
            target = local_path(reference, current, files)
            if target in pages and target not in reachable:
                pending.append(target)
            fragment = urlsplit(reference).fragment
            if fragment and target in pages and fragment not in pages[target].ids:
                raise ValueError(f'{current}: missing fragment {fragment}')
    if reachable | {'404.html'} != set(pages):
        raise ValueError('Every page must be linked from the site')


def build_catalog(source=ROOT / 'sites'):
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Unsafe source directory')
    directories = sorted(p for p in source.iterdir() if p.is_dir() or p.is_symlink())
    if {p.name for p in directories} != EXPECTED_IDS:
        raise ValueError('Expected exactly the twenty supported site directories')
    sites = []
    for folder in directories:
        if folder.is_symlink():
            raise ValueError('Site symlink not allowed')
        entries = sorted(folder.rglob('*'))
        if any(p.is_symlink() for p in entries):
            raise ValueError('Source symlink not allowed')
        meta = json.loads((folder / 'site.json').read_text(encoding='utf-8'))
        if set(meta) != {'id','title','description'} or meta['id'] != folder.name:
            raise ValueError('Invalid site metadata')
        if not re.fullmatch(r'[a-z][a-z0-9-]{1,39}', meta['id']):
            raise ValueError('Invalid site id')
        for key, maximum in [('title',100),('description',500)]:
            if not isinstance(meta[key], str) or not meta[key].strip() or len(meta[key]) > maximum or any(ord(c) < 32 for c in meta[key]):
                raise ValueError('Invalid catalogue text')
        files = {}
        for item in entries:
            if item.is_dir() or item.name == 'site.json':
                continue
            name = item.relative_to(folder).as_posix()
            if not item.is_file() or item.suffix not in EXTENSIONS or not re.fullmatch(r'[a-z0-9][a-z0-9._/-]{0,119}', name):
                raise ValueError(f'Unexpected site file {name}')
            if '..' in PurePosixPath(name).parts or item.stat().st_size > 128 * 1024:
                raise ValueError('Site file exceeds bounds')
            files[name] = item.read_text(encoding='utf-8').replace('\r\n','\n')
        if len(files) > 64:
            raise ValueError('Too many site files')
        validate_site(files)
        sites.append({**meta, 'files': files})
    data = (json.dumps({'schema':1,'sites':sites},ensure_ascii=False,separators=(',',':'))+'\n').encode('utf-8')
    if len(data) > MAX_BYTES:
        raise ValueError(f'Catalogue is {len(data)} bytes; maximum is {MAX_BYTES}')
    return data


def build_catalog_helper(data):
    if len(data) > MAX_BYTES:
        raise ValueError('Catalogue exceeds the byte limit')
    helper = (HELPER_PREFIX + repr(data.decode('utf-8')) + '\n').encode('utf-8')
    if len(helper) > MAX_BYTES:
        raise ValueError(f'Catalogue helper is {len(helper)} bytes; maximum is {MAX_BYTES}')
    return helper


def main():
    parser = argparse.ArgumentParser(description='Build the deterministic, local-only node website catalogue.')
    parser.add_argument('--source', type=Path, default=ROOT / 'sites')
    parser.add_argument('--output', type=Path, default=ROOT / 'installer/node-sites.json')
    parser.add_argument('--helper-output', type=Path, help='Defaults to node_site_catalog.py beside --output')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        data = build_catalog(args.source)
        helper = build_catalog_helper(data)
        helper_output = args.helper_output or args.output.with_name('node_site_catalog.py')
        if helper_output.resolve() == args.output.resolve():
            raise ValueError('JSON and helper output paths must differ')
        artifacts = [(args.output, data), (helper_output, helper)]
        if args.check:
            for output, expected in artifacts:
                if not output.is_file() or output.read_bytes() != expected:
                    raise ValueError(f'{output.name} is missing or stale; run build-node-sites.py')
        else:
            for output, expected in artifacts:
                output.parent.mkdir(parents=True, exist_ok=True)
                temporary = output.with_name(output.name + '.tmp')
                try:
                    temporary.write_bytes(expected)
                    temporary.replace(output)
                finally:
                    temporary.unlink(missing_ok=True)
        print(f'{"Checked" if args.check else "Built"} 20 sites: {len(data)} JSON / {len(helper)} helper UTF-8 bytes')
    except (ValueError, OSError, ET.ParseError) as error:
        print(f'Catalogue error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
