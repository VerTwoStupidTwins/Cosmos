"""Synthetic credential publication, never production credentials or state."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('state_setup', Path(sys.argv.pop(1)))
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class PrivateFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.original = self.root / 'client.json'
        self.original.write_bytes(b'{"apiKey":"public-fixture-token"}')
        self.original.chmod(0o600)
        self.credentials = self.root / 'credentials'
        self.credentials.mkdir(mode=0o700)
        (self.credentials / 'home-0').write_bytes(self.original.read_bytes())
        (self.credentials / 'home-0').chmod(0o400)
        self.manifest = {'environment': {}, 'credential_count': 0, 'files': {'honcho.json': {'credential': 'home-0', 'trusted_source': str(self.original)}}}

    def render(self):
        return state.render_files(self.manifest, str(self.credentials), root_uid=os.geteuid())

    def test_private_credential_bytes_are_published_as_file_not_path(self):
        self.assertTrue(self.render()['honcho.json'] == self.original.read_bytes())

    def test_changed_original_does_not_publish_stale_credential_copy(self):
        self.original.write_bytes(b'changed public fixture')
        with self.assertRaises(ValueError):
            self.render()

    def test_credential_name_cannot_escape_credential_directory(self):
        self.manifest['files']['honcho.json']['credential'] = '../client.json'
        with self.assertRaises(ValueError):
            self.render()

    def test_symlink_source_refused(self):
        alias = self.root / 'source-link'
        alias.symlink_to(self.original)
        self.manifest['files']['honcho.json']['trusted_source'] = str(alias)
        with self.assertRaises((OSError, ValueError)):
            self.render()

    def test_group_readable_source_is_not_accepted_as_private(self):
        self.original.chmod(0o640)
        with self.assertRaises(ValueError):
            self.render()


if __name__ == '__main__':
    unittest.main()
