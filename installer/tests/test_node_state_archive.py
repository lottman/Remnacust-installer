import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


def archive(members):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as output:
        for name, kind, contents in members:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.size = len(contents) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = '/outside'
            output.addfile(info, io.BytesIO(contents) if kind == tarfile.REGTYPE else None)
    stream.seek(0)
    return stream


class NodeStateArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_private_content_is_copied_from_a_stream(self):
        source = archive([('.', tarfile.DIRTYPE, b''), ('quota', tarfile.DIRTYPE, b''),
                          ('quota/ledger.json', tarfile.REGTYPE, b'known spent credit'),
                          ('usage',tarfile.DIRTYPE,b''),('usage/receipt.json',tarfile.REGTYPE,b'pending receipt')])
        self.assertEqual(runtime.extract_node_state_archive(source, self.root), 5)
        self.assertEqual((self.root / 'quota/ledger.json').read_bytes(), b'known spent credit')
        self.assertEqual((self.root / 'usage/receipt.json').read_bytes(), b'pending receipt')

    def test_size_and_entry_limits_are_checked_before_content_is_written(self):
        with self.assertRaises(runtime.ConfigurationError):
            runtime.extract_node_state_archive(archive([('huge', tarfile.REGTYPE, b'x' * 100)]), self.root, byte_limit=10)
        self.assertFalse((self.root / 'huge').exists())
        with self.assertRaises(runtime.ConfigurationError):
            runtime.extract_node_state_archive(archive([('a', tarfile.REGTYPE, b'a'), ('b', tarfile.REGTYPE, b'b')]), self.root, entry_limit=1)
        self.assertFalse((self.root / 'b').exists())

    def test_links_paths_devices_and_duplicate_files_cannot_overwrite_data(self):
        for index, (name, kind) in enumerate([
            ('../outside', tarfile.REGTYPE), ('/outside', tarfile.REGTYPE),
            ('link', tarfile.SYMTYPE), ('hard', tarfile.LNKTYPE), ('device', tarfile.CHRTYPE),
        ]):
            target = self.root / str(index)
            target.mkdir()
            with self.assertRaises(runtime.ConfigurationError):
                runtime.extract_node_state_archive(archive([(name, kind, b'wrong')]), target)
            self.assertEqual(list(target.iterdir()), [])
        with self.assertRaises(FileExistsError):
            runtime.extract_node_state_archive(archive([('same', tarfile.REGTYPE, b'first'), ('same', tarfile.REGTYPE, b'second')]), self.root)
        self.assertEqual((self.root / 'same').read_bytes(), b'first')

    def test_disk_headroom_is_retained_before_writing_a_file(self):
        with patch.object(runtime.shutil, 'disk_usage', return_value=type('Space', (), {'free': 1024})()):
            with self.assertRaises(runtime.ConfigurationError):
                runtime.extract_node_state_archive(archive([('data', tarfile.REGTYPE, b'data')]), self.root)
        self.assertFalse((self.root / 'data').exists())

    def test_pax_metadata_is_bounded_before_tarfile_allocates_its_payload(self):
        header = tarfile.TarInfo('oversized-metadata')
        header.type = tarfile.XHDTYPE
        header.size = 2 * 1024**2
        with self.assertRaises(runtime.ConfigurationError):
            runtime.extract_node_state_archive(io.BytesIO(header.tobuf()), self.root)


if __name__ == '__main__':
    unittest.main()
